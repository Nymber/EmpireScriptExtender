# Choose the next controlled input by separating currently plausible models.
# Scores are heuristic posterior weights, so the report calls this information
# gain over model predictions, not a calibrated probability of causal truth.
require_relative "sysid"

module Behavior
  module Active
    DEFAULTS = [
      { "name" => "stop", "u" => { "fwd" => 0, "turn" => 0 } },
      { "name" => "move-straight", "u" => { "fwd" => 1, "turn" => 0 } },
      { "name" => "turn-in-place", "u" => { "fwd" => 0, "turn" => 1 } },
      { "name" => "move-and-turn", "u" => { "fwd" => 1, "turn" => 1 } }
    ].freeze

    def self.rank(trace, field, steps: 5, temperature: 0.03, tolerance: nil, candidates: DEFAULTS)
      raise "temperature must be positive" unless temperature.to_f.positive?
      raise "prediction tolerance must be positive" if tolerance && !tolerance.to_f.positive?
      res = SysId.analyse(trace, field)
      return { error: res[:error] } if res[:error]
      ranked = res[:ranked]
      best = ranked.first.score
      plausible = ranked.select { |r| r.score <= best + 0.35 }
      plausible = [ranked.first] if plausible.empty?
      weights = Num.normalize(plausible.map { |r| Math.exp(-[(r.score - best) / temperature, 700].min) })
      last = trace.series(field).compact.last
      return { error: "field +0x#{field} is missing from trace" } if last.nil?
      vals = trace.series(field).compact.map(&:to_f)
      spread = vals.empty? ? 0.0 : vals.max - vals.min
      tol = tolerance || [spread * 0.01, 1e-6].max
      prior_h = Num.entropy(weights)

      scored = candidates.map do |candidate|
        action = candidate.fetch("u", {})
        n = (candidate["steps"] || steps).to_i
        raise "candidate #{candidate['name']} has invalid step count" unless n.positive? && n <= 500
        forecasts = plausible.map do |r|
          value = last.to_f
          n.times { value = r.model.predict(value, action) }
          value
        end
        bins = Hash.new { |h, k| h[k] = [] }
        forecasts.each_with_index { |v, i| bins[(v / tol).round] << i }
        conditional_h = bins.values.sum do |idxs|
          mass = idxs.sum { |i| weights[i] }
          mass * Num.entropy(Num.normalize(idxs.map { |i| weights[i] }))
        end
        { name: candidate.fetch("name"), steps: n, u: action,
          gain_bits: [prior_h - conditional_h, 0.0].max,
          predicted: plausible.each_with_index.map { |r, i| [r.model.name, forecasts[i]] } }
      end.sort_by { |c| -c[:gain_bits] }
      { field: field, prior_entropy: prior_h, tolerance: tol,
        model_weights: plausible.each_with_index.map { |r, i| [r.model.name, weights[i], r.score] },
        candidates: scored }
    end

    def self.load_candidates(path)
      doc = JSON.parse(File.read(path))
      rows = doc.is_a?(Array) ? doc : doc.fetch("experiments")
      raise "experiments must be an array" unless rows.is_a?(Array) && !rows.empty?
      rows
    end
  end
end

if $PROGRAM_NAME == __FILE__
  def value(name, fallback = nil)
    i = ARGV.index("--#{name}")
    i && ARGV[i + 1] && !ARGV[i + 1].start_with?("--") ? ARGV[i + 1] : fallback
  end
  file = ARGV.find { |a| !a.start_with?("--") }
  unless file
    warn "usage: ruby active.rb <trace.jsonl> [--field 48] [--steps 5] [--candidates experiments.json]"
    exit 2
  end
  tr = Behavior::Trace.load(file)
  field = Behavior::Trace.normalize_key(value("field", tr.fields.first))
  candidates = value("candidates") ? Behavior::Active.load_candidates(value("candidates")) : Behavior::Active::DEFAULTS
  out = Behavior::Active.rank(tr, field, steps: value("steps", "5").to_i, candidates: candidates)
  if out[:error]
    warn out[:error]
    exit 1
  end
  puts "+0x#{out[:field]}: next experiment ranked by model disagreement (heuristic)"
  puts "model entropy #{format('%.3f', out[:prior_entropy])} bits; prediction tolerance #{format('%.6g', out[:tolerance])}"
  out[:candidates].each_with_index do |c, i|
    puts format("%d. %-20s expected separation %.3f bits; input=%s steps=%d", i + 1, c[:name], c[:gain_bits], c[:u].inspect, c[:steps])
    puts "   " + c[:predicted].map { |n, v| "#{n}=#{format('%.5g', v)}" }.join(" | ")
  end
  puts "Weights approximate relative model support from current fit scores; run the experiment and collect its outcome before naming the field."
end
