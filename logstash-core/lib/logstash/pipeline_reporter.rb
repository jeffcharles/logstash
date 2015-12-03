# encoding: utf-8
require 'ostruct'

module LogStash; class PipelineReporter
  attr_reader :logger, :pipeline

  # This is an immutable copy of the pipeline state,
  # It is a proxy to a hash to allow us to add methods dynamically to the hash
  class Snapshot
    def initialize(data)
      @data = data
    end

    def to_hash
      @data
    end

    def to_simple_hash
      {"inflight_count" => inflight_count, "stalling_thread_info" => format_threads_by_plugin}
    end

    def to_str
      to_simple_hash.to_s
    end
    alias_method :to_s, :to_str

    def method_missing(meth)
      @data[meth]
    end

    def format_threads_by_plugin
      stalled_plugins = {}
      stalling_threads_info.each do |thr|
        key = (thr.delete("plugin") || "other")
        stalled_plugins[key] ||= []
        stalled_plugins[key] << thr
      end
      stalled_plugins
    end
  end

  def initialize(logger,pipeline)
    @logger = logger
    @pipeline = pipeline
  end

  # The main way of accessing data from the reporter,,
  # this provides a (more or less) consistent snapshot of what's going on in the
  # pipeline with some extra decoration
  def snapshot
    Snapshot.new(self.to_hash)
  end

  def to_hash
    pipeline.inflight_batches_synchronize do |batch_map|
      worker_states_snap = worker_states(batch_map) # We only want to run this once
      inflight_count = worker_states_snap.map {|s| s[:inflight_count] }.reduce(0, :+)
      {
        :events_filtered => events_filtered,
        :events_consumed => events_consumed,
        :worker_count => pipeline.worker_threads.size,
        :inflight_count => inflight_count,
        :worker_states => worker_states_snap,
        :output_info => output_states,
        :thread_info => pipeline.plugin_threads_info,
        :stalling_threads_info => pipeline.stalling_threads_info
      }
    end
  end

  private

  def events_filtered
    pipeline.events_filtered.value
  end

  def events_consumed
    pipeline.events_consumed.value
  end

  def plugin_threads
    pipeline.plugin_threads
  end

  # Not threadsafe! must be called within an `inflight_batches_synchronize` block
  def worker_states(batch_map)
      pipeline.worker_threads.map.with_index do |thread,idx|
        status = thread.status || "dead"
        inflight_count = batch_map[thread] ? batch_map[thread].size : 0
        {
          :status => status,
          :alive => thread.alive?,
          :index => idx,
          :inflight_count => inflight_count
        }
    end
  end

  def output_states
    pipeline.outputs.map do |output|
      is_multi_worker = output.workers > 1

      idle, busy = if is_multi_worker
                     aw_size = output.available_workers.size
                     [aw_size, output.workers - aw_size]
                   else
                     output.single_worker_mutex.locked? ? [0,1] : [1,0]
                   end

      {
        :type => output.class.config_name,
        :config => output.config,
        :is_multi_worker => is_multi_worker,
        :workers => output.workers,
        :busy_workers => busy,
        :idle_workers => idle
      }
    end
  end
end end