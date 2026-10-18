module Brewster
  # Fans events out from the (thread-side) session to every attached WS
  # subscriber (fiber-side) without blocking the reactor: emit writes the
  # JSON line to per-subscriber pipes; the WS task blocks on its pipe's
  # reader end (scheduler-aware wait_readable).
  class Bridge
    def initialize
      @mutex = Mutex.new
      @writers = {} # reader.object_id => writer IO
      @ring = []    # last 64 event lines for late-attach replay
    end

    # Returns the reader end of a fresh pipe. Replay lines are written
    # before anyone else can emit, so no event between log read and
    # subscribe is missed.
    def subscribe(replay: [])
      reader, writer = IO.pipe
      @mutex.synchronize do
        @writers[reader.object_id] = writer
        replay.each { |line| safe_write(writer, line) }
      end
      reader
    end

    # Detaches the subscriber that owns reader; closes the writer end.
    def unsubscribe(reader)
      writer = nil
      @mutex.synchronize do
        writer = @writers.delete(reader.object_id)
      end
      writer&.close unless writer&.closed?
    rescue IOError
      nil
    end

    # Writes a JSON line to every subscriber. Slow (full-pipe) consumers
    # are silently dropped at the tail for the POC; dead pipes are culled.
    def write(line)
      @mutex.synchronize do
        @ring << line
        @ring.shift while @ring.length > 64
        @writers.each do |rid, writer|
          @writers.delete(rid) unless safe_write(writer, line)
        end
      end
    end

    def close_all
      @mutex.synchronize do
        @writers.each_value { |w| w.close unless w.closed? }
        @writers.clear
        @ring.clear
      end
    rescue IOError
      nil
    end

    private

    # Returns true if the line was queued/written, false if the pipe is dead.
    def safe_write(io, line)
      return false if io.closed?
      io.write_nonblock(line + "\n")
      true
    rescue IO::WaitWritable
      true # full pipe: drop tail rather than block the emitting thread
    rescue Errno::EPIPE, Errno::EBADF, IOError
      false
    end
  end
end