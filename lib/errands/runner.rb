module Errands

  module ThreadAccessor

    def self.extended(klass)
      klass.include PrivateAccess
    end

    def thread_accessor(*accessors)
      accessors.each do |a|
        define_method a, -> { our[a] }
        define_method "#{a}=", ->(v) { our[a] = v }
      end
    end

    module PrivateAccess

      def err(h = {})
        his_store! Thread.current, h
      end

      private

      def our_store!(h = nil)
        Thread.main[:errands] = h || {}
      end

      def his_store!(thread, h = nil)
        thread[:errands] = h || {}
      end

      def my
        Thread.current[:errands]
      end

      def his(thread)
        thread[:errands]
      end

      def our
        Thread.main[:errands]
      end

    end

  end

  module Started

    def start(*_)
      new(*_).tap &:start
    end

    def run(*_)
      new(*_).tap do |e|
        Process.daemon if (callee = __callee__) == :daemon
        startups << define_method(:startups_alternate_run) { { callee => true } } if __callee__ != __method__
        e.run
      end
    end

    alias_method :daemon, :run
    alias_method :threaded_run, :run
    alias_method :noop_run, :run

    def started_workers(*_)
      (@started_workers ||= [:worker]).concat _.flatten.map(&:to_sym)
    end

    def startups
      @startups ||= [:minimal_startup]
    end

    private

    def default_workers(*_)
      started_workers(*_).tap { |s| s.delete :worker }
    end

  end

  class Receptors < Hash

    class Receptor < Array

      module Track

        def track(v, r = nil)
          v.__send__ "instance_variable_#{r ? :set : :get}", *["@receptor_track", r].compact
        rescue => e
          my.merge!(data: v, error: :tracking_error)
          raise e
        end

      end

      include ThreadAccessor::PrivateAccess
      include Track

      attr_reader :name

      def initialize(name)
        @name = name
      end

      def shift(*_)
        my[:data] = super.tap { |value| my.merge! receptor_track: track(value), latency: empty? }
      end

      def <<(value)
        return if value.nil?
        track value, my[:receptor_track]
        super.tap { our[:threads][@name] && our[:threads][@name].run }
      end

    end

    def default(key)
      self[key] = Receptor.new key
    end

  end

  class Runners < Hash

    include ThreadAccessor::PrivateAccess

    def [](k)
      v = super
      v if v && v.alive?
    end

    def []=(k, v)
      our[k] = super if v.is_a? Thread
    end

    def delete(k)
      our.delete k
      super
    end

    def stopping_order(all = false)
      scope(:type, :starter).merge(scope(:type, :data_acquisition)).merge all ? self : {}
    end

    def key_sliced(*list)
      select_keys = keys & list.flatten
      typecast select { |k, v| select_keys.include? k }
    end

    def alive
      typecast select { |k, v| self[k] }
    end

    def scope(s, value = true)
      typecast select { |k, v| his(v)[s] == value }
    end

    private

    def typecast(h)
      self.class.new.merge! h
    end

  end

  module LousyCompat

    def worker
      working :worker, :process, :job
    end

  end

  module Runner

    def self.included(klass)
      klass.extend(ThreadAccessor).extend(Started)
      klass.thread_accessor :events, :receptors, :threads
    end

    attr_accessor :running_mode

    def start(options = {})
      our_store! startups.merge(options)
      starter
    end

    def run(options = startups)
      start options unless started?
      our.merge! events: receptors[:events]
      our[:threaded_run] || our[:noop_run] ? running { main_loop } : main_loop
    end

    def starter(*_)
      if our[:starter]
        self.class.started_workers *_
      elsif !our[:noop_run]
        starting self.class.started_workers
      end
    end

    def starting(started)
      log_activity ["Starting #{self.class} in #{$0} (#{$$}), at #{Time.now}, with :", our[:config], "workers : #{started}", "\n"].join("\n")

      running thread_name, loop: true, started: started, type: :starter do
        Array(my[:started]).uniq.each { |s| threads[s] ||= send *(respond_to?(s, true) ? [s] : [:working, s]) }
        sleep frequency || 1
      end
    end

    def working(*_)
      work_done, processing, data_acquisition = working_jargon *_
      our[work_done] = false

      running _.first, loop: true, type: :data_acquisition do
        unless my[:stop] ||= our[work_done] = checked_send("#{work_done}?")
          r = ready_receptor! processing
          ((r << send(data_acquisition)) && !my[:latency]) || sleep(frequency.to_i)
        end
      end
    end

    def exit_on_stop
      stop
      exit
    end

    def stop(*_)
      [false, true].each do |all|
        list = threads.key_sliced(_.any? ? _ : stopped_threads)
        list.alive.each { |n, t| his(t)[:stop] = true }
        list.stopping_order(all).alive.each { |n, t| exiting(n, !all || t.stop?) }
      end

      stopped?
      threads.key_sliced(_.any? ? _ : stopped_threads).alive.empty?
    end

    def status
      {}.tap { |s| threads.each { |name, t| s[name] = t.status } }
    end

    def wait_for(key, meth = nil, result = true)
      time = Time.now.to_f
      loop {
        break if @errands_wait_timeout && Time.now.to_f - time > @errands_wait_timeout
        break if meth && our[key].respond_to?(meth, true) ?
          ((our[key].send(meth) == result) rescue nil) :
          !!our[key] == result }
    end

    def stopped?
      our[:stopped] = threads.key_sliced(stopped_threads).alive.empty?.tap { |bool|
        log_activity Time.now, "#{self.class} #{name rescue nil} : All activities stopped" if bool
      }
    end

    def started?
      !!our && !!threads && our[:started] = !stopped?
    end

    private

    def minimal_startup
      { threads: Runners.new, receptors: Receptors.new }
    end

    def frequency(name = nil)
      our[:config] && our[:config][:frequencies] && our[:config][:frequencies][name || my[:name]]
    end

    def main_loop
      rescued_loop do
        (e = events.shift) ? errands(*e) : sleep(frequency(:main_loop) || 1)
      end

      log_activity Time.now, "#{self.class} #{name rescue nil} : Exiting main loop"
    end

    def ready_receptor!(processing)
      receptors[processing].tap { threads[processing] ||= spring processing }
    end

    def spring(processing)
      running processing, loop: true, deletable: true do
        data = receptors[my[:name]].shift || Thread.stop || receptors[my[:name]].shift
        data && send(processing, data).tap do |r|
          if my[:receptor_track] && my[:receptor_track][:receptor].name != my[:name]
            my[:receptor_track][:receptor] << my[:receptor_track].merge(result: r).reject { |k, v| k == :receptor }
          end
        end
      end
    end

    def errands(errand, *_)
      running("#{thread_name(1)}_#{errand}".to_sym, deletable: true) { send errand, *_ }
    end

    def running(name = thread_name, options = {}, &block)
      if @running_mode
        send @running_mode, &block
      else
        threads[name] = Thread.new {
          (my && my[:name] && (my[:named] = true)) || Thread.stop || (my[:named] = true)
          r = my[:result] = rescued_execution &block
          ["stop_#{name}", our[name] && "stop_#{his(our[name])[:type]}"].compact.each { |s| checked_send s }
          my[:deletable] && threads.delete(name)
          r
        }.tap { |t|
          his_store! t, { name: name, time: Time.now.to_f, stop: false, type: :any, receptor_track: my && my.delete(:receptor_track) }.merge(options)
          t.run unless his(t)[:named]
        }
      end
    end

    def exiting(name, force = true)
      force && Thread.current == our[name] ? errands(:exiting, name) : our[name] && (force || our[name].stop?) && our[name].exit
      wait_for name, :alive?, false
    end

    def stopped_threads
      our[:stopped_threads] || threads.keys.reject { |k| k.to_s =~ /^errands_.+_stop$/}
    end

    def thread_name(caller_depth = 2)
      caller_locations(caller_depth, 1).first.base_label.dup.tap { |n|
        n << "_" << Time.now.to_f.to_s.sub('.', '_') if n.end_with? 's'
      }.to_sym
    end

    def rescued_execution
      loop do
        our["#{my[:name]}_iteration".to_sym] = begin
          my[:stop] ? break : yield; Time.now
        rescue => e
          my[:logged] = Time.now.to_f
          log_error e, my[:data], my
        rescue Exception => e
          my[:logged] = Time.now.to_f
          log_error e, my[:data], my
          raise e
        end

        my[:loop] || break
      end
    end

    def rescued_loop(&block)
      my[:loop] = true
      rescued_execution &block
    end

    def checked_send(meth, recipient = self, *_)
      recipient.respond_to?(meth, true) && (recipient.send(meth, *_) rescue nil)
    end

    def working_jargon(started, processing = nil, data_acquisition = nil)
      [ "#{started}_done".to_sym,
        processing || "#{started}_process".to_sym,
        data_acquisition || "#{started}_data_acquisition".to_sym ]
    end

    def log_error(e, data, *_)
      puts(e) || puts(e.message) || puts(data) || puts(e.backtrace) || puts(_) if our[:verbose]
    end

    def log_activity(*_)
      return unless our[:quiet]

      message = _.map(&:to_s).join(" ")
      # message = activity if message.empty?
      puts message
    end

    def startups
      self.class.startups
        .dup
        .tap { |s| s << :startup if respond_to?(:startup, true) }
        .uniq
        .inject({}) { |s, m| extended_merge(s, __send__(m)) }
    end

    def extended_merge(from, to)
      from.tap do |f|
        to.keys.each do |k|
          f[k] = f[k].is_a?(Hash) && to[k].is_a?(Hash) ? extended_merge(f[k], to[k]) : to[k]
        end
      end
    end

  end

end
