require "spec_helper"

class NeedRunner

  include Errands::Runner

  thread_accessors :bim, :bam, :pile

  def initialize(options)
    @future_running_mode = options[:running_mode]
    @limit = options[:limit]
    @exit_on_limit = options[:exit_on_limit]
  end

  def startup
    { bim: :bim_value,
      bam: :bam_value,
      pile: [],
      limit: @limit,
      exit_on_limit: @exit_on_limit,
      frequency: 1
    }
  end

  def start
    super
    wait_for :worker
    @running_mode = @future_running_mode if @future_running_mode
  end

  def job
    Dir['*']
  end

  def process(job)
    pile.concat job
  end

  def other_job
    running do
      sleep 100
    end
  end

  def different_running
    running do
      our[:different_running] = Thread.current
    end
  end

  def work_done?
    our[:limit] && pile.size >= our[:limit]
  end

  def work_done
    if our[:exit_on_limit]
      (our[:events] ||= [])<< [:stop]
      sleep
    else
      pile.clear
      our[:limit] = 10000
    end
  end

end

describe NeedRunner do
  let(:needy) {
    described_class.new running_mode: running_mode,
                        limit: limit,
                        exit_on_limit: exit_on_limit
  }
  let(:running_mode) { nil }
  let(:limit) { nil }
  let(:exit_on_limit) { nil }

  describe "thread_accessors" do
    before {
      needy.our[:bam] = :that_bam
      needy.our[:bim] = :that_bim
    }

    it "should have defined accessors" do
      expect(needy.bam).to eq :that_bam
      expect(needy.bim).to eq :that_bim
    end
  end

  describe "run (start)" do
    before {
      needy.start
    }

    it "should have launched basic function threads" do
      expect(needy.status.values.size).to eq 2
      expect(needy.status[:starter]).to be_alive
      expect(needy.status[:worker]).to be_alive
    end

    it "should have set accessors values" do
      expect(needy.bim).to eq :bim_value
      expect(needy.bam).to eq :bam_value
      expect(needy.pile).to be_an_instance_of Array
    end
  end

  describe "starter job" do
    before {
      needy.start
      needy.our[:previous_worker] = needy.our[:worker]
      needy.stop :worker
      needy.wait_for :worker, :alive?
    }

    it "should restart a defunct worker" do
      expect(needy.our[:worker]).not_to eq needy.our[:previous_worker]
    end
  end

  describe "breaking_loop and work_done" do
    let(:limit) { 40 }

    context "exit" do
      let(:exit_on_limit) { true }

      before {
        needy.start
        needy.wait_for :work_done
      }

      it "should have stopped after reaching the limit" do
        expect(needy.status.values.all? { |t| t.status == 'sleep' }).to be_truthy
        expect(needy.pile.size).to be >= limit
        expect(needy.our[:events]).to eq [[:stop]]
        expect(needy.our[:worker].status).to eq "sleep"
      end
    end

    context "no exit" do
      before {
        needy.start
        needy.our[:previous_worker] = needy.our[:worker]
        needy.wait_for :worker, :alive?, false
        needy.wait_for :worker, :alive?
      }

      it "should have stopped after reaching the limit" do
        expect(needy.our[:worker]).not_to eq needy.our[:previous_worker]
        expect(needy.our[:work_done]).to be_falsy
      end
    end

    describe "stop" do
      before {
        needy.start
        needy.other_job
        needy.wait_for :worker, :alive?
        needy.stop [:starter, :worker]
      }

      it "should have stopped basic threads" do
        expect([ needy.our[:starter], needy.our[:worker] ].any? { |t| t.alive? }).to be_falsy
        expect(needy.our[:stopped]).to be_falsy
      end

      context "all stopped" do
        before{
          needy.stop :other_job
        }

        it "should have set the stopped flag" do
          expect(needy.our[:other_job].alive?).to be_falsy
          expect(needy.our[:stopped]).to be_truthy
        end
      end
    end

    describe "running_mode" do
      let(:running_mode) { :instance_exec }

      before {
        needy.start
        needy.different_running
      }

      it "should not have used threads" do
        expect(needy.our[:different_running]).to eq Thread.main
      end
    end
  end

  after {
    needy.stop
    needy.wait_for :stopped
    needy.our.clear
    needy.my.clear
  }
end
