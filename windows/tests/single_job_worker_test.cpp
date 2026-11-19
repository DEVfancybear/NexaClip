#include "../runner/single_job_worker.h"
#include "../runner/start_with_cleanup.h"

#include <chrono>
#include <cstdlib>
#include <future>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <thread>

#define CHECK(x) do { if (!(x)) { std::cerr << "CHECK failed: " #x << " at " << __LINE__ << '\n'; std::abort(); } } while (false)

using Worker = SingleJobWorker<int, int>;

static Worker::Result TakeEventually(Worker& worker) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    auto result = worker.TryTake();
    if (result) return std::move(*result);
    std::this_thread::yield();
  }
  std::abort();
}

struct ThrowingInput {
  ThrowingInput() = default;
  bool fail = true;
  ThrowingInput(ThrowingInput&& other) : fail(other.fail) {
    if (fail) throw std::runtime_error("move failed");
  }
  ThrowingInput(const ThrowingInput&) = delete;
};

static void TestFailedStart() {
  using ThrowWorker = SingleJobWorker<ThrowingInput, int>;
  ThrowWorker worker([](ThrowingInput) { return 1; });
  ThrowingInput input;
  CHECK(worker.TryStart(std::move(input)) == ThrowWorker::StartResult::unavailable);
  CHECK(!worker.TryTake());
  input.fail = false;
  CHECK(worker.TryStart(std::move(input)) == ThrowWorker::StartResult::started);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  std::optional<ThrowWorker::Result> result;
  while (!(result = worker.TryTake()) && std::chrono::steady_clock::now() < deadline) {
    std::this_thread::yield();
  }
  CHECK(result && result->index() == 0 && std::get<0>(*result) == 1);
  worker.Shutdown();
}

static void TestRejectedInputOwnership() {
  using MoveWorker = SingleJobWorker<std::unique_ptr<int>, int>;
  std::promise<void> entered;
  std::promise<void> release;
  auto gate = release.get_future().share();
  MoveWorker worker([&](std::unique_ptr<int> input) {
    entered.set_value();
    gate.wait();
    return *input;
  });
  auto first = std::make_unique<int>(11);
  CHECK(worker.TryStart(std::move(first)) == MoveWorker::StartResult::started);
  CHECK(!first);
  CHECK(entered.get_future().wait_for(std::chrono::seconds(5)) == std::future_status::ready);
  auto busy = std::make_unique<int>(22);
  CHECK(worker.TryStart(std::move(busy)) == MoveWorker::StartResult::busy);
  CHECK(busy && *busy == 22);
  release.set_value();
  worker.Shutdown();
  auto stopped = std::make_unique<int>(33);
  CHECK(worker.TryStart(std::move(stopped)) == MoveWorker::StartResult::stopped);
  CHECK(stopped && *stopped == 33);
}

static void TestShutdownWithUnclaimedWork() {
  std::promise<void> finished_work;
  Worker worker([&](int value) {
    finished_work.set_value();
    return value;
  });
  CHECK(worker.TryStart(7) == Worker::StartResult::started);
  CHECK(finished_work.get_future().wait_for(std::chrono::seconds(5)) == std::future_status::ready);
  CHECK(worker.TryStart(8) == Worker::StartResult::busy);
  worker.Shutdown();
  CHECK(!worker.TryTake());
  CHECK(worker.TryStart(9) == Worker::StartResult::stopped);
}

static void TestShutdownWhileRunning() {
  std::promise<void> entered;
  std::promise<void> release;
  std::promise<void> stopping;
  auto gate = release.get_future().share();
  auto stopped = std::async(std::launch::async, [&] {
    Worker worker([&](int value) {
      entered.set_value();
      gate.wait();
      return value;
    });
    CHECK(worker.TryStart(5) == Worker::StartResult::started);
    CHECK(entered.get_future().wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    stopping.set_value();
    worker.Shutdown();
    CHECK(!worker.TryTake());
    CHECK(worker.TryStart(6) == Worker::StartResult::stopped);
    worker.Shutdown();
  });
  CHECK(stopping.get_future().wait_for(std::chrono::seconds(5)) == std::future_status::ready);
  CHECK(stopped.wait_for(std::chrono::milliseconds(50)) == std::future_status::timeout);
  release.set_value();
  CHECK(stopped.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
  stopped.get();
}

static void TestStartCleanup() {
  int cleanup_count = 0;
  auto cleanup = [&] { ++cleanup_count; };
  CHECK(StartWithCleanup([] { return true; }, cleanup));
  CHECK(cleanup_count == 0);
  CHECK(!StartWithCleanup([] { return false; }, cleanup));
  CHECK(cleanup_count == 1);
  try {
    StartWithCleanup([]() -> bool { throw std::runtime_error("start"); }, cleanup);
    CHECK(false);
  } catch (const std::runtime_error&) {
    CHECK(cleanup_count == 2);
  }
  try {
    StartWithCleanup([]() -> bool { throw 7; }, cleanup);
    CHECK(false);
  } catch (int error) {
    CHECK(error == 7 && cleanup_count == 3);
  }
}

int main() {
  TestStartCleanup();
  TestFailedStart();
  TestRejectedInputOwnership();
  TestShutdownWithUnclaimedWork();
  TestShutdownWhileRunning();
  std::promise<void> entered;
  std::promise<void> release;
  auto gate = release.get_future().share();
  Worker worker([&](int value) {
    if (value == 1) {
      entered.set_value();
      gate.wait();
    }
    if (value == 3) throw std::runtime_error("synthetic");
    return value * 2;
  });
  CHECK(worker.TryStart(1) == Worker::StartResult::started);
  CHECK(entered.get_future().wait_for(std::chrono::seconds(5)) == std::future_status::ready);
  CHECK(worker.TryStart(2) == Worker::StartResult::busy);
  CHECK(!worker.TryTake());
  release.set_value();
  auto first = TakeEventually(worker);
  CHECK(std::get<0>(first) == 2);
  CHECK(!worker.TryTake());
  CHECK(worker.TryStart(2) == Worker::StartResult::started);
  auto second = TakeEventually(worker);
  CHECK(std::get<0>(second) == 4);
  CHECK(worker.TryStart(3) == Worker::StartResult::started);
  auto failure = TakeEventually(worker);
  CHECK(failure.index() == 1);
  try {
    std::rethrow_exception(std::get<1>(failure));
  } catch (const std::runtime_error&) {
    worker.Shutdown();
    worker.Shutdown();
    CHECK(worker.TryStart(4) == Worker::StartResult::stopped);
    Worker replacement([](int value) { return value * 2; });
    CHECK(replacement.TryStart(4) == Worker::StartResult::started);
    auto recovered = TakeEventually(replacement);
    CHECK(recovered.index() == 0 && std::get<0>(recovered) == 8);
    replacement.Shutdown();
    return 0;
  }
  return 1;
}
