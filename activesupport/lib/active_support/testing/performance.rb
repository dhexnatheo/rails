require 'fileutils'
require 'rails/version'
require 'active_support/core_ext/class/delegating_attributes'
require 'active_support/core_ext/string/inflections'

if !defined?(RUBY_ENGINE) or RUBY_ENGINE == "ruby" # MRI 1.8 or 1.9
  begin
    require 'ruby-prof'
  rescue LoadError
    $stderr.puts "Specify ruby-prof as application's dependency in Gemfile to run benchmarks."
    exit
  end
  
  require 'active_support/testing/performance/mri'
end

module ActiveSupport
  module Testing
    module Performance      
      DEFAULTS =
        if benchmark = ARGV.include?('--benchmark')  # HAX for rake test
          { :benchmark => true,
            :runs => 4,
            :metrics => [:wall_time, :memory, :objects, :gc_runs, :gc_time],
            :output => 'tmp/performance' }
        else
          { :benchmark => false,
            :runs => 1,
            :min_percent => 0.01,
            :metrics => [:process_time, :memory, :objects],
            :formats => [:flat, :graph_html, :call_tree],
            :output => 'tmp/performance' }
        end.freeze

      def self.included(base)
        base.superclass_delegating_accessor :profile_options
        base.profile_options = DEFAULTS
      end

      def full_test_name
        "#{self.class.name}##{method_name}"
      end

      def run(result)
        return if method_name =~ /^default_test$/

        yield(self.class::STARTED, name)
        @_result = result

        run_warmup
        if profile_options && metrics = profile_options[:metrics]
          metrics.each do |metric_name|
            if klass = Metrics[metric_name.to_sym]
              run_profile(klass.new)
              result.add_run
            end
          end
        end

        yield(self.class::FINISHED, name)
      end

      def run_test(metric, mode)
        run_callbacks :setup
        setup
        metric.send(mode) { __send__ @method_name }
      rescue ::Test::Unit::AssertionFailedError => e
        add_failure(e.message, e.backtrace)
      rescue StandardError, ScriptError => e
        add_error(e)
      ensure
        begin
          teardown
          run_callbacks :teardown, :enumerator => :reverse_each
        rescue ::Test::Unit::AssertionFailedError => e
          add_failure(e.message, e.backtrace)
        rescue StandardError, ScriptError => e
          add_error(e)
        end
      end

      protected
        def run_profile(metric)
          klass = profile_options[:benchmark] ? Benchmarker : Profiler
          performer = klass.new(self, metric)

          performer.run
          puts performer.report
          performer.record
        end

      class Performer
        delegate :run_test, :profile_options, :full_test_name, :to => :@harness

        def initialize(harness, metric)
          @harness, @metric = harness, metric
        end

        def report
          rate = @total / profile_options[:runs]
          '%20s: %s' % [@metric.name, @metric.format(rate)]
        end

        protected
          def output_filename
            "#{profile_options[:output]}/#{full_test_name}_#{@metric.name}"
          end
      end

      class Benchmarker < Performer
        def run
          profile_options[:runs].to_i.times { run_test(@metric, :benchmark) }
          @total = @metric.total
        end

        def record
          avg = @metric.total / profile_options[:runs].to_i
          now = Time.now.utc.xmlschema
          with_output_file do |file|
            file.puts "#{avg},#{now},#{environment}"
          end
        end

        def environment
          unless defined? @env
            app = "#{$1}.#{$2}" if File.directory?('.git') && `git branch -v` =~ /^\* (\S+)\s+(\S+)/

            rails = Rails::VERSION::STRING
            if File.directory?('vendor/rails/.git')
              Dir.chdir('vendor/rails') do
                rails += ".#{$1}.#{$2}" if `git branch -v` =~ /^\* (\S+)\s+(\S+)/
              end
            end

            ruby = defined?(RUBY_ENGINE) ? RUBY_ENGINE : 'ruby'
            ruby += "-#{RUBY_VERSION}.#{RUBY_PATCHLEVEL}"

            @env = [app, rails, ruby, RUBY_PLATFORM] * ','
          end

          @env
        end

        protected
          HEADER = 'measurement,created_at,app,rails,ruby,platform'

          def with_output_file
            fname = output_filename

            if new = !File.exist?(fname)
              FileUtils.mkdir_p(File.dirname(fname))
            end

            File.open(fname, 'ab') do |file|
              file.puts(HEADER) if new
              yield file
            end
          end

          def output_filename
            "#{super}.csv"
          end
      end
      
      module Metrics
        def self.[](name)
          const_get(name.to_s.camelize)
        rescue NameError
          nil
        end

        class Base
          attr_reader :total

          def initialize
            @total = 0
          end

          def name
            @name ||= self.class.name.demodulize.underscore
          end

          def measure_mode
            self.class::Mode
          end

          def measure
            0
          end

          def benchmark
            with_gc_stats do
              before = measure
              yield
              @total += (measure - before)
            end
          end
        end
        
        class Time < Base
          def measure
            ::Time.now.to_f
          end

          def format(measurement)
            if measurement < 1
              '%d ms' % (measurement * 1000)
            else
              '%.2f sec' % measurement
            end
          end
        end
      end
    end
  end
end
