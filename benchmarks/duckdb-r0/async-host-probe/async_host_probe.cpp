// Minimal protocol probe for the DuckDB v1.5.6 task/async-host boundary
// (Sluice #578 R5, mission e5-closure §8.4).
//
// Links against the prebuilt, SHA-pinned libduckdb (no DuckDB source change)
// and drives the real TaskScheduler with three deterministic probes:
//
//   P1  early-return task — a task that submits external I/O and returns
//       before completion. Mirrors AsyncExecutionTask's accounting
//       (src/parallel/async_result.cpp:34-40): the completion counter fires on
//       task RETURN. Expected: the accounting resume edge fires while the I/O
//       is still in flight, i.e. this task kind would let the pipeline read
//       uninitialized data. Inadmissible without host support.
//
//   P2  submit-and-wait task — a task that submits and blocks its executing
//       thread until external completion, then returns. Correct data, but the
//       single worker is pinned for the whole latency and a task queued behind
//       it cannot start. This is the submit+wait sync wrapper, not true async.
//
//   P3  TASK_BLOCKED task — a task that returns TASK_BLOCKED on the plain
//       scheduler. Expected: executed once, descheduled, never revived by any
//       scheduler-internal driver; revival requires the Executor machinery
//       (InterruptState::Callback -> Executor::RescheduleTask) whose production
//       drivers in v1.5.6 are all in-process.
//
// Every wait uses atomic happens-before edges or clock spins that only lengthen
// an observation window; no assertion depends on timing luck.
//
// Exit code 0 = all three probes behaved as predicted.

#include "duckdb/common/common.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/parallel/task.hpp"
#include "duckdb/parallel/task_scheduler.hpp"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <thread>
#include <unistd.h>

using namespace duckdb;
using Clock = std::chrono::steady_clock;

namespace {

constexpr size_t kIoSize = 4096;

#define CHECK(cond, msg)                                                                                               \
	do {                                                                                                               \
		if (!(cond)) {                                                                                                 \
			std::fprintf(stderr, "PROBE FAIL: %s (at %s:%d)\n", msg, __FILE__, __LINE__);                              \
			std::exit(1);                                                                                              \
		}                                                                                                              \
	} while (false)

double MillisBetween(Clock::time_point a, Clock::time_point b) {
	return std::chrono::duration<double, std::milli>(b - a).count();
}

// A simulated external async I/O backend, shaped like an io_uring backend:
// the backend thread parks until `released`; completion is observable only
// through the backend's `completed` flag. `submitted`/`released`/`completed`
// are the only edges; nothing is time-based.
struct SimBackend {
	int fd = -1;
	off_t offset = 0;
	char *buffer = nullptr;

	std::thread worker;
	std::atomic<bool> submitted {false};
	std::atomic<bool> released {false};
	std::atomic<bool> completed {false};
	Clock::time_point completion_time;

	void Start() {
		worker = std::thread([this] {
			while (!released.load(std::memory_order_acquire)) {
				std::this_thread::yield();
			}
			ssize_t n = pread(fd, buffer, kIoSize, offset);
			if (n != static_cast<ssize_t>(kIoSize)) {
				std::fprintf(stderr, "PROBE FAIL: backend pread returned %zd\n", n);
				std::exit(1);
			}
			completion_time = Clock::now();
			completed.store(true, std::memory_order_release);
		});
	}
	void Release() {
		released.store(true, std::memory_order_release);
	}
	void Join() {
		worker.join();
	}
};

// Mirrors the AsyncResult/AsyncExecutionTask completion accounting: a shared
// atomic counter sized to the task batch; the thread that drives it to zero
// records the accounting "resume" edge (async_result.cpp:14-25, 36-38).
struct MirrorCounter {
	std::atomic<idx_t> count {1};
	Clock::time_point resume_time;

	void FinishOne() {
		if (count.fetch_sub(1, std::memory_order_acq_rel) == 1) {
			resume_time = Clock::now();
		}
	}
	void WaitResume() {
		while (count.load(std::memory_order_acquire) != 0) {
			std::this_thread::yield();
		}
	}
};

struct Probe {
	TaskScheduler &scheduler;
	ProducerToken &token;
	int fd = -1;
	const char *path;

	char expected[kIoSize];
	char buffer[kIoSize];

	void MakeFile() {
		for (size_t i = 0; i < kIoSize; i++) {
			expected[i] = static_cast<char>(i * 31 + 7);
		}
		fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
		if (fd < 0) {
			std::fprintf(stderr, "PROBE FAIL: cannot create %s\n", path);
			std::exit(1);
		}
		ssize_t w = write(fd, expected, kIoSize);
		if (w != static_cast<ssize_t>(kIoSize)) {
			std::fprintf(stderr, "PROBE FAIL: short write\n");
			std::exit(1);
		}
		fsync(fd);
	}

	bool DataCorrect() const {
		return std::memcmp(buffer, expected, kIoSize) == 0;
	}

	// P1: submit and return immediately — the shape of an adapter that
	// mistakes "task returned" for "I/O completed".
	void RunP1() {
		SimBackend backend;
		backend.fd = fd;
		backend.offset = 0;
		backend.buffer = buffer;
		std::memset(buffer, 0xAB, kIoSize); // poison: any correct byte at resume = accounting bug
		backend.Start();

		MirrorCounter counter;
		auto task = make_shared_ptr<EarlyReturnTask>(backend, counter);
		scheduler.ScheduleTask(token, task);

		counter.WaitResume(); // the accounting resume edge: counter == 0 on task return

		bool submitted_at_resume = backend.submitted.load(std::memory_order_acquire);
		bool completed_at_resume = backend.completed.load(std::memory_order_acquire);
		bool correct_at_resume = completed_at_resume && DataCorrect();
		Clock::time_point resume_time = counter.resume_time;

		backend.Release(); // real completion happens now, driven externally
		backend.Join();
		bool correct_after_completion = DataCorrect();

		std::printf("P1 early-return task:\n");
		std::printf("  accounting resume fired       : yes (counter==0 when Execute returned)\n");
		std::printf("  I/O submitted at resume       : %s\n", submitted_at_resume ? "yes" : "NO");
		std::printf("  I/O completed at resume       : %s\n", completed_at_resume ? "YES (unexpected)" : "no");
		std::printf("  data correct at resume        : %s\n", correct_at_resume ? "YES (unexpected)" : "NO");
		std::printf("  data correct after completion : %s\n", correct_after_completion ? "yes" : "no");
		CHECK(submitted_at_resume, "P1: submission not visible at resume");
		CHECK(!completed_at_resume, "P1: I/O unexpectedly complete at accounting resume");
		CHECK(!correct_at_resume, "P1: data unexpectedly correct at accounting resume");
		CHECK(correct_after_completion, "P1: data wrong even after external completion");
		CHECK(resume_time < backend.completion_time, "P1: resume edge not before completion");
		std::printf("  VERDICT: the resume edge fires while the I/O is in flight. An early-return task\n"
		            "            kind would hand the pipeline a garbage chunk. INADMISSIBLE without a\n"
		            "            pending/completion state owned by the host.\n\n");
	}

	class EarlyReturnTask : public Task {
	public:
		SimBackend &backend;
		MirrorCounter &counter;

		EarlyReturnTask(SimBackend &b, MirrorCounter &c) : backend(b), counter(c) {
		}

		TaskExecutionResult Execute(TaskExecutionMode mode) override {
			backend.submitted.store(true, std::memory_order_release);
			counter.FinishOne();
			(void)mode;
			return TaskExecutionResult::TASK_FINISHED;
		}
		string TaskType() const override {
			return "EarlyReturnReadTask";
		}
	};

	// P2: submit and block the executing thread until the backend completes —
	// the shape of a wait_one() call inside AsyncTask::Execute().
	void RunP2() {
		SimBackend backend;
		backend.fd = fd;
		backend.offset = 0;
		backend.buffer = buffer;
		std::memset(buffer, 0xAB, kIoSize);
		backend.Start();

		MirrorCounter counter;
		std::atomic<bool> task_started {false};
		Clock::time_point start_time;
		Clock::time_point return_time;
		std::thread::id worker_id;

		struct SubmitAndWaitTask : public Task {
			SimBackend &backend;
			MirrorCounter &counter;
			std::atomic<bool> &task_started;
			Clock::time_point &start_time;
			Clock::time_point &return_time;
			std::thread::id &worker_id;

			SubmitAndWaitTask(SimBackend &b, MirrorCounter &c, std::atomic<bool> &started,
			                  Clock::time_point &start_p, Clock::time_point &return_p, std::thread::id &worker_p)
			    : backend(b), counter(c), task_started(started), start_time(start_p), return_time(return_p),
			      worker_id(worker_p) {
			}

			TaskExecutionResult Execute(TaskExecutionMode mode) override {
				start_time = Clock::now();
				worker_id = std::this_thread::get_id();
				backend.submitted.store(true, std::memory_order_release);
				task_started.store(true, std::memory_order_release);
				while (!backend.completed.load(std::memory_order_acquire)) {
					std::this_thread::yield();
				}
				counter.FinishOne();
				return_time = Clock::now();
				(void)mode;
				return TaskExecutionResult::TASK_FINISHED;
			}
			string TaskType() const override {
				return "SubmitAndWaitReadTask";
			}
		};

		// Queued behind the read task on the same producer, executed by the
		// same single worker.
		std::atomic<bool> heartbeat_done {false};
		Clock::time_point heartbeat_start;
		struct Heartbeat : public Task {
			std::atomic<bool> &done;
			Clock::time_point &start;
			Heartbeat(std::atomic<bool> &d, Clock::time_point &s) : done(d), start(s) {
			}
			TaskExecutionResult Execute(TaskExecutionMode mode) override {
				start = Clock::now();
				done.store(true, std::memory_order_release);
				(void)mode;
				return TaskExecutionResult::TASK_FINISHED;
			}
			string TaskType() const override {
				return "Heartbeat";
			}
		};

		auto task = make_shared_ptr<SubmitAndWaitTask>(backend, counter, task_started, start_time, return_time,
		                                               worker_id);
		auto heartbeat = make_shared_ptr<Heartbeat>(heartbeat_done, heartbeat_start);
		scheduler.ScheduleTask(token, task);
		scheduler.ScheduleTask(token, heartbeat);

		while (!task_started.load(std::memory_order_acquire)) {
			std::this_thread::yield();
		}

		// Occupancy observation window: the backend is still parked, the read
		// task is still waiting in Execute(). The window length only scales
		// the measured pin; no assertion depends on its duration.
		const auto window = std::chrono::milliseconds(3);
		const auto window_end = start_time + window;
		bool heartbeat_ran_during_window = false;
		while (Clock::now() < window_end) {
			if (heartbeat_done.load(std::memory_order_acquire)) {
				heartbeat_ran_during_window = true;
				break;
			}
			std::this_thread::yield();
		}
		bool heartbeat_blocked_while_waiting = !heartbeat_ran_during_window;

		backend.Release(); // let the real I/O complete
		counter.WaitResume();
		backend.Join();
		while (!heartbeat_done.load(std::memory_order_acquire)) {
			std::this_thread::yield();
		}

		bool correct_at_resume = DataCorrect();
		double pinned_ms = MillisBetween(start_time, return_time);

		std::printf("P2 submit-and-wait task:\n");
		std::printf("  executed on scheduler worker       : %s\n",
		            worker_id != std::this_thread::get_id() ? "yes" : "no");
		std::printf("  data correct at resume             : %s\n", correct_at_resume ? "yes" : "NO");
		std::printf("  worker pinned by in-thread wait    : %.3f ms\n", pinned_ms);
		std::printf("  queued heartbeat blocked meanwhile : %s\n", heartbeat_blocked_while_waiting ? "yes" : "NO");
		CHECK(worker_id != std::this_thread::get_id(), "P2: task did not run on a scheduler worker");
		CHECK(correct_at_resume, "P2: data wrong at resume");
		CHECK(return_time >= backend.completion_time, "P2: task returned before backend completion");
		CHECK(heartbeat_blocked_while_waiting, "P2: queued task ran while worker was pinned");
		CHECK(heartbeat_start >= return_time, "P2: heartbeat ran before read task returned");
		std::printf("  VERDICT: correct data, but the executing thread waits for the request inside\n"
		            "            Execute(); each in-flight I/O pins one DuckDB worker for the full\n"
		            "            latency and starves queued tasks. This is the submit+wait sync\n"
		            "            wrapper, NOT completion-driven async.\n\n");
	}

	// P3: TASK_BLOCKED on the plain scheduler.
	void RunP3() {
		std::atomic<idx_t> executions {0};
		std::atomic<bool> descheduled {false};

		struct BlockedTask : public Task {
			std::atomic<idx_t> &executions;
			std::atomic<bool> &descheduled;
			BlockedTask(std::atomic<idx_t> &e, std::atomic<bool> &d) : executions(e), descheduled(d) {
			}
			TaskExecutionResult Execute(TaskExecutionMode mode) override {
				executions.fetch_add(1, std::memory_order_acq_rel);
				(void)mode;
				return TaskExecutionResult::TASK_BLOCKED;
			}
			void Deschedule() override {
				descheduled.store(true, std::memory_order_release);
			}
			string TaskType() const override {
				return "BlockedTask";
			}
		};

		auto task = make_shared_ptr<BlockedTask>(executions, descheduled);
		scheduler.ScheduleTask(token, task);

		while (!descheduled.load(std::memory_order_acquire)) {
			std::this_thread::yield();
		}
		// Observe for revival without any external driver: the queue must drain
		// and the task must stay executed-exactly-once.
		while (scheduler.GetNumberOfTasks() != 0) {
			std::this_thread::yield();
		}
		idx_t final_executions = executions.load(std::memory_order_acquire);
		bool queue_empty = scheduler.GetNumberOfTasks() == 0;

		std::printf("P3 TASK_BLOCKED task:\n");
		std::printf("  executed once then descheduled : %s\n", final_executions == 1 ? "yes" : "no");
		std::printf("  scheduler queue drained        : %s\n", queue_empty ? "yes" : "no");
		std::printf("  revived by scheduler           : no (no scheduler-internal revival driver)\n");
		CHECK(final_executions == 1, "P3: task executed more than once");
		CHECK(queue_empty, "P3: task remained queued");
		// Revival is Executor-only: ExecutorTask::Deschedule ->
		// Executor::AddToBeRescheduled, and the only production Callback
		// drivers are intra-process (aggregate partition handoff, batch memory
		// manager) or DUCKDB_DEBUG_ASYNC_SINK_SOURCE test threads. Nothing
		// revives a blocked task on an external I/O completion in v1.5.6.
		std::printf("  VERDICT: TASK_BLOCKED has no scheduler-level pending state. Revival is owned by\n"
		            "            Executor reschedule machinery whose drivers today are in-process only.\n"
		            "            True completion-driven async requires a host change: a pending task\n"
		            "            state plus an external completion driver.\n\n");
	}

	void Run() {
		MakeFile();
		RunP1();
		RunP2();
		RunP3();
		close(fd);
	}
};

} // namespace

int main() {
	DuckDB db(nullptr);
	auto scheduler = make_uniq<TaskScheduler>(*db.instance);
	scheduler->SetThreads(2, 1); // exactly one background worker
	scheduler->RelaunchThreads();
	// NumberOfThreads() counts background workers plus external threads; P2's
	// heartbeat assertion is the binding one-worker check (a second worker
	// would run the heartbeat inside the occupancy window and fail P2).
	CHECK(scheduler->NumberOfThreads() >= 1, "expected the background worker to launch");
	auto token = scheduler->CreateProducer();

	Probe probe {*scheduler, *token};
	probe.path = "/tmp/sluice-r5-async-host-probe.bin";
	probe.Run();

	std::printf("ALL PROBES BEHAVED AS PREDICTED (exit 0)\n");
	return 0;
}
