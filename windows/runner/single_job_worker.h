#ifndef RUNNER_SINGLE_JOB_WORKER_H_
#define RUNNER_SINGLE_JOB_WORKER_H_

#include <exception>
#include <functional>
#include <mutex>
#include <optional>
#include <thread>
#include <type_traits>
#include <utility>
#include <variant>

// Start, TryTake and Shutdown belong to one owner thread. Work never calls it.
template <typename Input, typename Output>
class SingleJobWorker {
  static_assert(std::is_nothrow_move_constructible_v<Output> &&
                std::is_nothrow_move_assignable_v<Output>,
                "Worker results must be movable without throwing");

 public:
  using Result = std::variant<Output, std::exception_ptr>;
  using Work = std::function<Output(Input)>;
  enum class StartResult { started, busy, stopped, unavailable };

  explicit SingleJobWorker(Work work) : work_(std::move(work)) {}
  ~SingleJobWorker() { Shutdown(); }
  SingleJobWorker(const SingleJobWorker&) = delete;
  SingleJobWorker& operator=(const SingleJobWorker&) = delete;

  // Busy/stopped leave input untouched. An unavailable thread may consume it;
  // the caller must report failure rather than retry with the moved input.
  StartResult TryStart(Input&& input) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) return StartResult::stopped;
    if (busy_) return StartResult::busy;
    busy_ = true;
    try {
      thread_ = std::thread([this, input = std::move(input)]() mutable {
        Result result = [&]() -> Result {
          try {
            return Result(std::in_place_index<0>, work_(std::move(input)));
          } catch (...) {
            return Result(std::in_place_index<1>, std::current_exception());
          }
        }();
        std::lock_guard<std::mutex> lock(mutex_);
        result_.emplace(std::move(result));
      });
    } catch (...) {
      busy_ = false;
      return StartResult::unavailable;
    }
    return StartResult::started;
  }

  std::optional<Result> TryTake() {
    std::optional<Result> result;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!result_) return std::nullopt;
      result = std::move(result_);
      result_.reset();
    }
    if (thread_.joinable()) thread_.join();
    busy_ = false;
    return result;
  }

  // Waits for Work to finish; a stuck encoder can therefore delay shutdown.
  void Shutdown() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopped_ = true;
    }
    if (thread_.joinable()) thread_.join();
    std::lock_guard<std::mutex> lock(mutex_);
    result_.reset();
    busy_ = false;
  }

 private:
  Work work_;
  std::mutex mutex_;
  std::thread thread_;
  std::optional<Result> result_;
  bool busy_ = false;
  bool stopped_ = false;
};

#endif  // RUNNER_SINGLE_JOB_WORKER_H_
