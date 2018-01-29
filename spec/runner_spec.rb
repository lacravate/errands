require "spec_helper"

class NeedRunner

  include Errands::Runner
  include Errands::LousyCompat

  thread_accessor :bim, :bam, :pile, :different_running_thread, :previous_worker

  def initialize(options)
    @future_running_mode = options[:running_mode]
    @limit = options[:limit]
    @exit_on_limit = options[:exit_on_limit]
  end

  def startup
    super.merge bim: :bim_value,
      bam: :bam_value,
      pile: [],
      limit: @limit,
      exit_on_limit: @exit_on_limit,
      frequency: 1
  end

  def start(*_)
    super
    our[:other_job_pile] = receptors[:other_job_pile]
    our[:dir] = receptors[:dir]
    wait_for :worker
    @running_mode = @future_running_mode if @future_running_mode
  end

  def job
    our[:dir].concat Dir['*']
    our[:dir].shift
  end

  def process(job)
    pile.push job
    job
  end

  def other_job
    running do
      i = 0
      rescued_loop do
        i += 1
        1 / (i - 1)
        s = i.to_s
        my[:receptor_track] = { receptor: our[:other_job_pile] }
        our[:dir] << s
        sleep 0.3
      end
    end
  end

  def different_running
    running do
      our[:different_running_thread] = Thread.current
    end
  end

  def worker_done?
    our[:limit] && pile.size >= our[:limit]
  end

  def worker_done_marker
    our[:worker_done]
  end

  def stop_worker
    worker_done
  end

  def worker_done
    if our[:exit_on_limit]
      (our[:events] ||= []) << [:stop]
      sleep
    else
      pile.clear
      our[:limit] = 1000
    end
  end

  def log_error(e, data, ctx)
    super || receptors[:errors] << e.message
    # puts e.backtrace
  end

end

class OtherRunner < NeedRunner

  started_workers << :other_job

  def stopped_threads
    super
  end

end

class EssentialRunner < NeedRunner

  started_workers << :other_job

  def stopped_threads
    super - [:other_job]
  end

end

describe NeedRunner do
  let(:needy) { described_class.new needy_params }
  let(:running_mode) { nil }
  let(:limit) { nil }
  let(:exit_on_limit) { nil }
  let(:start_needy) { true }
  let(:needy_params) {
    { running_mode: running_mode,
      limit: limit,
      exit_on_limit: exit_on_limit }
  }

  before {
    Errands::TestHelpers::Wrapper.help needy if start_needy
  }

  describe 'new' do
    let(:start_needy) { false }

    it "should not be started with only new" do
      expect(needy.started?).to be_falsy
    end
  end

  describe "thread_accessor" do
    before {
      needy.bam = :that_bam
      needy.bim = :that_bim
    }

    it "should have defined accessors" do
      expect(needy.bam).to eq :that_bam
      expect(needy.bim).to eq :that_bim
    end
  end

  describe "start" do
    before {
      needy.wait_for :worker_iteration
    }

    it "should have launched basic function threads" do
      expect(needy.status.values.size).to eq 3
      expect(needy.status[:starter]).not_to be_falsy
      expect(needy.status[:worker]).not_to be_falsy
      expect(needy.status[:process]).not_to be_falsy
    end

    it "should have set accessors values" do
      expect(needy.bim).to eq :bim_value
      expect(needy.bam).to eq :bam_value
      expect(needy.pile).to be_a_kind_of Array
    end
  end

  describe "starter job" do
    before {
      needy.previous_worker = needy.threads[:worker]
      needy.stop :worker
      needy.wait_for :worker, :alive?
    }

    it "should restart a defunct worker" do
      expect(needy.threads[:worker]).not_to eq needy.previous_worker
    end
  end

  describe "breaking_loop and work_done" do
    let(:limit) { 40 }

    context "exit" do
      let(:exit_on_limit) { true }

      before {
        needy.wait_for :worker_done
      }

      it "should have stopped after reaching the limit" do
        expect(needy.status.values.uniq).to eq ['sleep']
        expect(needy.pile.size).to be >= limit
        expect(needy.events).to eq [[:stop]]
        expect(needy.threads[:worker].status).to eq "sleep"
      end
    end

    context "no exit" do
      before {
        needy.previous_worker = needy.threads[:worker]
        needy.wait_for :worker, :alive?, false
        needy.wait_for :worker, :alive?
      }

      it "should have stopped after reaching the limit" do
        expect(needy.threads[:worker]).not_to eq needy.previous_worker
        expect(needy.worker_done_marker).to be_falsy
      end
    end

    describe 'receptor_track' do
      let(:needy) { OtherRunner.new needy_params }

      before {
        needy.wait_for :other_job_pile, :size, 3
      }

      it "should have stashed products of other_job in a specific pile" do
        expect(needy.receptors[:other_job_pile].map {|e|e[:result]}).to eq %w|2 3 4|
      end
    end

    describe "stop" do
      context "OtherRunner" do
        let(:needy) { OtherRunner.new needy_params }

        before {
          needy.wait_for :worker, :alive?
          needy.wait_for :other_job, :alive?
          needy.stop :starter, :worker
        }

        it "should respond to started? accordintgly" do
          expect(needy.started?).to be_truthy
        end

        it "should have set another worker to be started" do
          expect(needy.class.started_workers).to eq [:worker, :other_job]
        end

        it "should have set another worker to be stopped when stop is required" do
          expect(needy.stopped_threads.sort).to eq [:other_job, :process, :starter, :worker]
        end

        it "should have stopped basic threads" do
          expect(needy.threads.values_at(:starter, :worker).any? { |t| t.alive? }).to be_falsy
          expect(needy.stopped?).to be_falsy
        end

        context "all stopped" do
          before{
            needy.stop
          }

          it "should have set the stopped flag" do
            expect(needy.threads[:other_job]).to be_nil
            expect(needy.stopped?).to be_truthy
          end
        end
      end

      context "EssentialRunner" do
        let(:needy) { EssentialRunner.new needy_params }

        before {
          needy.wait_for :worker, :alive?
          needy.wait_for :other_job, :alive?
          needy.stop :starter, :worker
        }

        it "should respond to started? accordintgly" do
          expect(needy.started?).to be_truthy
        end

        it "should have set another worker to be started" do
          expect(needy.class.started_workers).to eq [:worker, :other_job]
        end

        it "should have set another worker to be stopped when stop is required" do
          expect(needy.stopped_threads.sort).to eq [:process, :starter, :worker]
        end

        it "should have stopped basic threads" do
          expect(needy.threads.values_at(:starter, :worker).any? { |t| t.alive? }).to be_falsy
          expect(needy.stopped?).to be_falsy
        end

        context "all stopped" do
          before{
            needy.stop
          }

          it "should have set the stopped flag" do
            expect(needy.stopped?).to be_truthy
            expect(needy.threads[:other_job]).to be_truthy
          end
        end
      end
    end

    describe "running_mode" do
      let(:running_mode) { :instance_exec }

      before {
        needy.different_running
      }

      it "should not have used threads" do
        expect(needy.different_running_thread).to eq Thread.main
      end
    end
  end

  describe 'run' do
    let(:start_needy) { false }

    before {
      Errands::TestHelpers::Wrapper.helper.helped needy
    }

    context "start && run" do
      before {
        Thread.new { needy.start; needy.run }
        sleep 0.3 while !needy.started?
        needy.wait_for :worker
        needy.wait_for :worker_iteration
      }

      it "should be properly run" do
        expect([needy.threads, needy.events, needy.receptors].all?).to be_truthy
        expect(needy.started?).to be_truthy
      end
    end

    context "run" do
      before {
        t = Thread.new { needy.run }
        t[:errands] ||= {}
        sleep 0.3 while !needy.started?
        needy.wait_for :worker
        needy.wait_for :worker_iteration
      }

      it "should be properly run" do
        expect([needy.threads, needy.events, needy.receptors].all?).to be_truthy
        expect(needy.started?).to be_truthy
      end

      context "events" do
        before {
          Errands::TestHelpers::Wrapper.helper.push_event [:stop]
          needy.wait_for :stopped
        }

        it "should have received stop signal" do
          expect(needy.stopped?).to be_truthy
        end
      end
    end

    describe "track" do

    end
  end

  after {
    Errands::TestHelpers::Wrapper.after
  }
end
