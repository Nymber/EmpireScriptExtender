# Summarize an observed finite-state variable and expose hidden-state evidence.
# State values are supplied by the user (or a trace phase); this does not infer
# semantic labels from arbitrary nearby memory.
require_relative "trace"

module Behavior
  module Automata
    def self.learn(trace, state_field, input_names: [])
      states = trace.series(state_field)
      rows = Hash.new { |h, k| h[k] = Hash.new(0) }
      trace.samples.each_cons(2) do |a, b|
        next unless b.t == a.t + 1
        from, to = a.x[Trace.normalize_key(state_field)], b.x[Trace.normalize_key(state_field)]
        next if from.nil? || to.nil?
        input = input_names.sort.map { |n| "#{n}=#{a.u.fetch(n, '?')}" }.join(",")
        rows[[from, input]][to] += 1
      end
      transitions = []
      ambiguous = []
      rows.each do |(from, input), dests|
        total = dests.values.sum
        probabilities = dests.values.map { |n| n.to_f / total }
        h = Num.entropy(probabilities)
        dests.each { |to, count| transitions << { from: from, input: input, to: to, count: count, probability: count.to_f / total } }
        ambiguous << { state: from, input: input, outcomes: dests, entropy_bits: h } if dests.size > 1
      end
      { states: states.compact.uniq, transitions: transitions,
        ambiguous: ambiguous, samples: trace.size }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  def value(name, fallback = nil)
    i = ARGV.index("--#{name}")
    i && ARGV[i + 1] && !ARGV[i + 1].start_with?("--") ? ARGV[i + 1] : fallback
  end
  file = ARGV.find { |a| !a.start_with?("--") }
  unless file && (field = value("state"))
    warn "usage: ruby automata.rb <trace.jsonl> --state <x-field> [--input fwd,turn]"
    exit 2
  end
  result = Behavior::Automata.learn(Behavior::Trace.load(file), field, input_names: value("input", "").split(",").reject(&:empty?))
  puts "state field +0x#{Behavior::Trace.normalize_key(field)}: #{result[:states].size} observed states, #{result[:transitions].size} transition rows"
  result[:transitions].each { |e| puts "  #{e[:from].inspect} --#{e[:input]}--> #{e[:to].inspect} (#{e[:count]}, p=#{format('%.2f', e[:probability])})" }
  result[:ambiguous].each do |a|
    puts "  AMBIGUOUS: same state/input has multiple futures #{a[:state].inspect}/#{a[:input].inspect}: #{a[:outcomes].inspect}"
  end
  puts "  A repeated state with different futures suggests a missing timer, target, flag, or noisy observation; it is not proof of which one." if result[:ambiguous].any?
end
