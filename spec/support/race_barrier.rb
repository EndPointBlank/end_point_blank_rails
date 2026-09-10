# frozen_string_literal: true

# A classic count-and-broadcast barrier, used by specs that need many threads
# to reach a starting line together and then go at the same instant, rather
# than trickling out one at a time.
#
# Racing a shared mutable memo (see spec/delayed_writer_spec.rb, sc-376) needs
# every thread hitting the memo's first access as close to simultaneously as
# possible to have any real chance of exposing a non-atomic `||=`. Repeatedly
# pushing onto a Queue does not do that: Queue#push wakes one waiter per push,
# not all of them, so waiters would be released one at a time. A
# Mutex+ConditionVariable#broadcast wakes every thread waiting on `wait` in
# the same call.
class RaceBarrier
  def initialize(count)
    @count = count
    @waiting = 0
    @mutex = Mutex.new
    @cv = ConditionVariable.new
  end

  def wait
    @mutex.synchronize do
      @waiting += 1
      if @waiting >= @count
        @cv.broadcast
      else
        @cv.wait(@mutex) while @waiting < @count
      end
    end
  end
end
