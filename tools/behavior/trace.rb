# trace.rb - the shared contract for every tool in this cluster.
#
# A TRACE is a recording of observed state over time, with the inputs that were
# applied. One JSON object per line (JSONL), so a capture can be appended to
# while the game runs and read by a half-finished analysis without parsing the
# whole file.
#
#   {"t":0,"phase":"stop","u":{"fwd":0,"turn":0},"x":{"48":1523.0,"4c":189.2}}
#
#   t      tick index (integer, monotonic; gaps allowed and reported)
#   phase  the controlled experiment this sample belongs to. OPTIONAL but it is
#          what turns a recording into evidence - see expdesign.rb.
#   u      inputs APPLIED at t (what we did)
#   x      observed state at t, keyed by field offset as lowercase hex, no 0x
#
# WHY OFFSET-KEYED AND NOT NAMED
#   Naming a field is the CONCLUSION, not the input. This project has already
#   named two fields wrongly and built on them for hours (+0x4C called "X" when
#   it is the height; +0x348 called "alive" from a single sample). The tools here
#   take offsets in and hand names back with a confidence attached.
#
# CONVENTIONS THAT MATTER
#   - A missing field is nil, never 0. "Absent" and "zero" are different claims.
#   - Values stay as read: floats as floats, integers as integers. bvsolve.rb
#     needs the integer to be an integer to reason about wraparound.
#   - Empire's Lua is FLOAT32 and quantises above 2^24, so an address that came
#     back through Lua arithmetic may be wrong. Capture reads bytes, not
#     computed addresses; see capture.ps1.

require "json"

module Behavior
  # One sample.
  Sample = Struct.new(:t, :phase, :u, :x, keyword_init: true)

  class Trace
    attr_reader :samples, :source

    def initialize(samples, source: nil)
      @samples = samples
      @source = source
    end

    def self.normalize_key(k)
      s = k.to_s.downcase.sub(/\A0x/, "").sub(/\A\+/, "")
      s.sub(/\A0+(?=.)/, "")   # 0048 and 48 are the same field
    end

    def self.load(path)
      samples = []
      File.foreach(path).with_index do |line, i|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        begin
          h = JSON.parse(line)
        rescue JSON::ParserError => e
          raise "#{path}:#{i + 1}: #{e.message}"
        end
        samples << Sample.new(
          t: h["t"] || i,
          phase: h["phase"],
          u: (h["u"] || {}).transform_keys(&:to_s),
          x: (h["x"] || {}).each_with_object({}) { |(k, v), o| o[normalize_key(k)] = v }
        )
      end
      raise "#{path}: no samples" if samples.empty?
      new(samples, source: path)
    end

    def self.save(path, samples)
      File.open(path, "w") do |f|
        samples.each do |s|
          h = { "t" => s.t }
          h["phase"] = s.phase if s.phase
          h["u"] = s.u unless s.u.nil? || s.u.empty?
          h["x"] = s.x
          f.puts JSON.generate(h)
        end
      end
      path
    end

    def size = @samples.size
    def fields = @samples.flat_map { |s| s.x.keys }.uniq.sort_by { |k| k.to_i(16) }
    def input_names = @samples.flat_map { |s| s.u.keys }.uniq.sort

    # Values for one field, in time order. nil where the field was not observed.
    def series(field)
      f = Trace.normalize_key(field)
      @samples.map { |s| s.x[f] }
    end

    def input(name) = @samples.map { |s| s.u[name.to_s] }

    def phases
      out = {}
      @samples.each_with_index { |s, i| (out[s.phase || "(unlabelled)"] ||= []) << i }
      out
    end

    # A sub-trace, so a model can be fitted on one controlled phase alone.
    def phase(name)
      Trace.new(@samples.select { |s| s.phase == name }, source: "#{@source}##{name}")
    end

    # Consecutive pairs only. A gap in t means the engine advanced without us
    # looking, so x_{t+1} = F(x_t, u_t) does not hold across it - skip it rather
    # than fitting a model to an interval we did not observe.
    def transitions(field)
      f = Trace.normalize_key(field)
      out = []
      @samples.each_cons(2) do |a, b|
        next unless b.t == a.t + 1
        va = a.x[f]
        vb = b.x[f]
        next if va.nil? || vb.nil?
        out << [va, vb, a.u, a.phase]
      end
      out
    end

    def gaps
      @samples.each_cons(2).filter_map { |a, b| [a.t, b.t] if b.t != a.t + 1 }
    end

    # Fields that never change are not necessarily constants - they may simply
    # not have been exercised. Report them separately rather than classifying.
    def static_fields
      fields.select do |f|
        v = series(f).compact
        v.empty? || v.uniq.size == 1
      end
    end

    def summary
      lines = ["trace #{@source}: #{size} samples, #{fields.size} fields, inputs #{input_names.join(', ')}"]
      g = gaps
      lines << "  WARNING: #{g.size} gap(s) in t, e.g. #{g.first(3).inspect} - transitions across them are skipped" unless g.empty?
      phases.each { |n, idx| lines << "  phase #{n.ljust(18)} #{idx.size} samples" }
      st = static_fields
      lines << "  never changed (not exercised?): #{st.join(' ')}" unless st.empty?
      lines.join("\n")
    end
  end

  # Shared numerics. Kept here so every tool scores the same way.
  module Num
    module_function

    def mean(a) = a.empty? ? 0.0 : a.sum(0.0) / a.size

    def rmse(pred, obs)
      n = [pred.size, obs.size].min
      return Float::INFINITY if n.zero?
      Math.sqrt((0...n).sum { |i| (pred[i].to_f - obs[i].to_f)**2 } / n)
    end

    # Residual scaled by the signal's own movement, so a field that ranges over
    # 2000 units and one that ranges over 0.5 are comparable. A model that
    # predicts a CONSTANT signal perfectly scores 0 either way.
    def nrmse(pred, obs)
      e = rmse(pred, obs)
      return e if e.infinite?
      spread = obs.compact.minmax.then { |lo, hi| (hi.to_f - lo.to_f).abs }
      spread < 1e-9 ? e : e / spread
    end

    # Least squares for y = a*x + b. Returns [a, b].
    def linfit(xs, ys)
      n = [xs.size, ys.size].min
      return [0.0, 0.0] if n.zero?
      mx = mean(xs.first(n).map(&:to_f))
      my = mean(ys.first(n).map(&:to_f))
      num = (0...n).sum { |i| (xs[i].to_f - mx) * (ys[i].to_f - my) }
      den = (0...n).sum { |i| (xs[i].to_f - mx)**2 }
      den.abs < 1e-12 ? [0.0, my] : [num / den, my - (num / den) * mx]
    end

    # Shannon entropy of a probability vector, in bits.
    def entropy(ps)
      ps.sum(0.0) { |p| p <= 0 ? 0.0 : -p * Math.log2(p) }
    end

    def normalize(ws)
      s = ws.sum(0.0)
      s <= 0 ? ws.map { 1.0 / ws.size } : ws.map { |w| w / s }
    end
  end
end
