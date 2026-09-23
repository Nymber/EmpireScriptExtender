# sysid.rb - what does this value MEAN?
#
# Fits competing models of x_{t+1} = F(x_t, u_t; theta) to an observed field and
# ranks them by fit AND complexity:
#
#   M* = argmin [ predictionError(M) + lambda * complexity(M) ]
#
# The point is not the winner. The point is the MARGIN: if two models fit almost
# equally well, the honest output is "ambiguous, and here is the experiment that
# would separate them" - not a name.
#
# THE QUESTION THIS EXISTS TO ANSWER
#   Two addresses move together while a soldier walks. Are both positions, or is
#   one an animation phase? Correlation cannot tell you. These models can, because
#   they disagree about what happens when the input STOPS:
#
#     position       holds its value       (integrator, input zero -> no change)
#     velocity       falls to zero         (proportional to input)
#     walk phase     freezes               (gated cycle)
#     idle phase     keeps advancing       (free-running cycle)
#     frame counter  keeps advancing       (and never wraps to a small period)
#
#   So one second of standing still is worth more than a minute of walking. That
#   is a claim about information, and expdesign.rb makes it quantitative.
#
# USAGE
#   ruby sysid.rb <trace.jsonl> [--field 48] [--lambda 0.02] [--verbose]
#   ruby sysid.rb <trace.jsonl> --all          # rank every field

require_relative "trace"

module Behavior
  module SysId
    # Each model fits its own parameters, then predicts x' from (x, u).
    class Model
      attr_reader :theta, :note

      def name = self.class::NAME
      def complexity = self.class::COMPLEXITY
      def meaning = self.class::MEANING
      def initialize = (@theta = {}; @note = nil)

      # Fit returns self, or nil when the model cannot apply to this data at all.
      def fit(_tr) = self
      def predict(_x, _u) = raise NotImplementedError

      def fwd(u) = (u["fwd"] || u["forward"] || u["move"] || 0).to_f
      def turn(u) = (u["turn"] || u["yaw"] || 0).to_f
      def moving?(u) = fwd(u).abs > 1e-6
      def turning?(u) = turn(u).abs > 1e-6

      def to_s
        p = @theta.empty? ? "" : " " + @theta.map { |k, v| "#{k}=#{fmt(v)}" }.join(" ")
        "#{name}#{p}"
      end

      def fmt(v) = v.is_a?(Float) ? format("%.4g", v) : v.to_s
    end

    # x' = x. Zero parameters, so it wins by default on anything that never moved.
    class Static < Model
      NAME = "static"; COMPLEXITY = 0
      MEANING = "constant, or simply never exercised - not the same claim"
      def predict(x, _u) = x
    end

    # x' = x + c, regardless of input. A frame counter or a free timer.
    class Counter < Model
      NAME = "counter"; COMPLEXITY = 1
      MEANING = "frame counter or free-running timer (advances with no input)"
      def fit(tr)
        d = tr.map { |a, b, _u, _p| b.to_f - a.to_f }
        return nil if d.empty?
        @theta[:c] = Num.mean(d)
        self
      end
      def predict(x, _u) = x.to_f + @theta[:c]
    end

    # x' = x + a*u_fwd. An INTEGRATOR of the movement input: a position.
    class IntegratorFwd < Model
      NAME = "integrator(fwd)"; COMPLEXITY = 1
      MEANING = "POSITION along a movement axis (accumulates the move input)"
      def fit(tr)
        xs = tr.map { |_a, _b, u, _p| fwd(u) }
        ys = tr.map { |a, b, _u, _p| b.to_f - a.to_f }
        return nil if xs.uniq.size < 2
        a, = Num.linfit(xs, ys)
        @theta[:a] = a
        self
      end
      def predict(x, u) = x.to_f + @theta[:a] * fwd(u)
    end

    # x' = x + a*u_turn. An integrator of the TURN input: a heading.
    class IntegratorTurn < Model
      NAME = "integrator(turn)"; COMPLEXITY = 1
      MEANING = "HEADING / orientation (accumulates the turn input)"
      def fit(tr)
        xs = tr.map { |_a, _b, u, _p| turn(u) }
        ys = tr.map { |a, b, _u, _p| b.to_f - a.to_f }
        return nil if xs.uniq.size < 2
        a, = Num.linfit(xs, ys)
        @theta[:a] = a
        self
      end
      def predict(x, u) = x.to_f + @theta[:a] * turn(u)
    end

    # x' = a*u_fwd + b. TRACKS the input rather than accumulating it: a velocity.
    class Proportional < Model
      NAME = "proportional(fwd)"; COMPLEXITY = 2
      MEANING = "VELOCITY / speed (tracks the input, does not accumulate)"
      def fit(tr)
        xs = tr.map { |_a, _b, u, _p| fwd(u) }
        ys = tr.map { |_a, b, _u, _p| b.to_f }
        return nil if xs.uniq.size < 2
        a, b = Num.linfit(xs, ys)
        @theta[:a] = a
        @theta[:b] = b
        self
      end
      def predict(_x, u) = @theta[:a] * fwd(u) + @theta[:b]
    end

    # x' = a*x + b. Decay, smoothing, or a lerp toward a target.
    class Decay < Model
      NAME = "decay(a*x+b)"; COMPLEXITY = 2
      MEANING = "smoothed/interpolated value (depends on itself, not the input)"
      def fit(tr)
        xs = tr.map { |a, _b, _u, _p| a.to_f }
        ys = tr.map { |_a, b, _u, _p| b.to_f }
        return nil if xs.uniq.size < 2
        a, b = Num.linfit(xs, ys)
        @theta[:a] = a
        @theta[:b] = b
        self
      end
      def predict(x, _u) = @theta[:a] * x.to_f + @theta[:b]
    end

    # Cyclic phase. GATED advances only while the input is non-zero (a walk
    # cycle); FREE advances always (an idle animation). Both wrap at a period,
    # and the wrap is what separates a phase from a counter.
    class Cycle < Model
      COMPLEXITY = 2
      def self.gated? = self::GATED
      def fit(tr)
        adv = tr.select { |_a, _b, u, _p| self.class.gated? ? moving?(u) : true }
        hold = tr.select { |_a, _b, u, _p| self.class.gated? ? !moving?(u) : false }
        return nil if adv.empty?

        steps = adv.map { |a, b, _u, _p| b.to_f - a.to_f }
        wraps, plain = steps.partition { |d| d < -1e-9 }
        return nil if plain.empty?
        d = Num.mean(plain)
        return nil if d.abs < 1e-9        # not advancing: this is not a cycle

        # At a wrap, x' = x + d - P, so P = x + d - x'.
        ps = adv.filter_map { |a, b, _u, _p| (a.to_f + d - b.to_f) if (b.to_f - a.to_f) < -1e-9 }
        # No wrap observed means no evidence of a period - that is Counter's
        # territory, and claiming a cycle here would be inventing the wrap.
        return nil if ps.empty?

        @theta[:d] = d
        @theta[:P] = Num.mean(ps)
        @note = "gated: held still in #{hold.size} stationary sample(s)" if self.class.gated? && !hold.empty?
        self
      end
      def predict(x, u)
        return x.to_f if self.class.gated? && !moving?(u)
        v = x.to_f + @theta[:d]
        v >= @theta[:P] ? v - @theta[:P] : v
      end
    end

    class CycleGated < Cycle
      NAME = "cycle(gated)"; GATED = true
      MEANING = "ANIMATION PHASE gated by movement (a walk cycle) - not a position"
    end

    class CycleFree < Cycle
      NAME = "cycle(free)"; GATED = false
      MEANING = "free-running animation phase or wrapping timer - not a position"
    end

    # x' = x + a*u_fwd + b*u_turn. The general 2-input integrator; it should only
    # win when a field genuinely responds to both.
    class IntegratorBoth < Model
      NAME = "integrator(fwd,turn)"; COMPLEXITY = 2
      MEANING = "position/orientation driven by BOTH inputs"
      def fit(tr)
        return nil if tr.size < 4
        # Two-variable least squares, solved directly.
        f = tr.map { |_a, _b, u, _p| fwd(u) }
        g = tr.map { |_a, _b, u, _p| turn(u) }
        y = tr.map { |a, b, _u, _p| b.to_f - a.to_f }
        return nil if f.uniq.size < 2 || g.uniq.size < 2
        sff = f.sum { |v| v * v }; sgg = g.sum { |v| v * v }
        sfg = f.each_with_index.sum { |v, i| v * g[i] }
        sfy = f.each_with_index.sum { |v, i| v * y[i] }
        sgy = g.each_with_index.sum { |v, i| v * y[i] }
        det = sff * sgg - sfg * sfg
        return nil if det.abs < 1e-12
        @theta[:a] = (sfy * sgg - sgy * sfg) / det
        @theta[:b] = (sgy * sff - sfy * sfg) / det
        self
      end
      def predict(x, u) = x.to_f + @theta[:a] * fwd(u) + @theta[:b] * turn(u)
    end

    ALL = [Static, Counter, IntegratorFwd, IntegratorTurn, Proportional,
           Decay, CycleGated, CycleFree, IntegratorBoth].freeze

    Result = Struct.new(:model, :err, :train_err, :score, :per_phase, keyword_init: true)

    # Fit every model to one field and rank them.
    def self.analyse(trace, field, lambda_c: 0.002)
      tr = trace.transitions(field)
      return { field: field, error: "no usable consecutive transitions" } if tr.size < 2
      unless tr.all? { |a, b, _u, _p| a.is_a?(Numeric) && b.is_a?(Numeric) && a.to_f.finite? && b.to_f.finite? }
        return { field: field, error: "field is categorical; use automata.rb instead of numeric system identification" }
      end

      # For a useful number of transitions, fit on alternating observations and
      # rank on the held-out half. With a short trace, use all available data but
      # mark the result low-evidence below; a perfect in-sample fit is not proof.
      if tr.size >= 8
        training = tr.each_with_index.filter_map { |row, i| row if i.even? }
        validation = tr.each_with_index.filter_map { |row, i| row if i.odd? }
      else
        training, validation = tr, tr
      end

      obs = validation.map { |_a, b, _u, _p| b.to_f }
      results = ALL.filter_map do |klass|
        m = klass.new.fit(training)
        next unless m
        pred = validation.map { |a, _b, u, _p| m.predict(a, u) }
        next if pred.any? { |v| v.nil? || (v.is_a?(Float) && !v.finite?) }
        err = Num.nrmse(pred, obs)
        train_obs = training.map { |_a, b, _u, _p| b.to_f }
        train_pred = training.map { |a, _b, u, _p| m.predict(a, u) }
        train_err = Num.nrmse(train_pred, train_obs)
        per = {}
        validation.each_with_index.group_by { |(_a, _b, _u, p), _i| p }.each do |ph, rows|
          pe = rows.map { |(_r, i)| pred[i] }
          oe = rows.map { |(_r, i)| obs[i] }
          per[ph || "(unlabelled)"] = Num.nrmse(pe, oe)
        end
        Result.new(model: m, err: err, train_err: train_err,
                   score: err + lambda_c * m.complexity, per_phase: per)
      end
      return { field: field, error: "no model could be fitted" } if results.empty?

      ranked = results.sort_by(&:score)
      { field: field, n: tr.size, train_n: training.size, validation_n: validation.size,
        ranked: ranked,
        margin: ranked.size > 1 ? ranked[1].score - ranked[0].score : Float::INFINITY }
    end

    # Which phase would most separate the top two models? That phase is where the
    # evidence actually lives, and if it is missing from the trace it is the
    # experiment to run next.
    def self.separating_phase(res)
      return nil unless res[:ranked] && res[:ranked].size > 1
      a, b = res[:ranked][0], res[:ranked][1]
      phase = (a.per_phase.keys & b.per_phase.keys)
        .max_by { |ph| (a.per_phase[ph] - b.per_phase[ph]).abs }
      return nil unless phase
      (a.per_phase[phase] - b.per_phase[phase]).abs > 1e-6 ? phase : nil
    end

    CONFIDENT = 0.05   # model-separation threshold, not probability of truth

    def self.report(res, verbose: false)
      out = []
      f = "+0x#{res[:field]}"
      if res[:error]
        out << "#{f}: #{res[:error]}"
        return out.join("\n")
      end
      best = res[:ranked][0]
      conf = if res[:n] < 10 || res[:validation_n] < 4
               "LOW DATA"
             elsif res[:margin] >= CONFIDENT
               "MODEL SUPPORTED"
             else
               "AMBIGUOUS"
             end
      out << "#{f}  #{conf}  (#{res[:n]} transitions; train #{res[:train_n]}, held-out #{res[:validation_n]}, margin #{format('%.3f', res[:margin])})"
      out << "   best: #{best.model}   err #{format('%.4f', best.err)}"
      out << "   candidate interpretation: #{best.model.meaning}"
      out << "   fit/held-out error: #{format('%.4f', best.train_err)} / #{format('%.4f', best.err)}"
      out << "   note: #{best.model.note}" if best.model.note

      if res[:margin] < CONFIDENT || conf == "LOW DATA"
        rival = res[:ranked][1]
        out << "   rival: #{rival.model} (err #{format('%.4f', rival.err)}) - #{rival.model.meaning}"
        ph = separating_phase(res)
        out << if ph && ph != "(unlabelled)"
                 "   THEY DISAGREE MOST IN PHASE '#{ph}'. Weight that phase, or collect more of it."
               else
                 "   NO PHASE SEPARATES THEM. Run a controlled experiment: " \
                 "stop (u=0), then turn-in-place, then move-straight. " \
                 "Use active.rb to rank which controlled input best separates the current models."
               end
      end

      if verbose
        out << "   all models:"
        res[:ranked].each { |r| out << format("     %-24s err %.4f  score %.4f", r.model.to_s, r.err, r.score) }
        out << "   per-phase error (best model):"
        best.per_phase.each { |ph, e| out << format("     %-18s %.4f", ph, e) }
      end
      out.join("\n")
    end
  end
end

if __FILE__ == $0
  def opt(n, d = nil)
    i = ARGV.index("--#{n}")
    i && ARGV[i + 1] && !ARGV[i + 1].start_with?("--") ? ARGV[i + 1] : d
  end

  path = ARGV.find { |a| !a.start_with?("--") }
  unless path
    puts "usage: ruby sysid.rb <trace.jsonl> [--field 48 | --all] [--lambda 0.002] [--verbose]"
    exit 1
  end
  tr = Behavior::Trace.load(path)
  puts tr.summary
  puts

  lam = (opt("lambda", "0.002")).to_f
  vb = ARGV.include?("--verbose")
  fields = if (f = opt("field"))
             [Behavior::Trace.normalize_key(f)]
           else
             tr.fields
           end

  fields.each do |f|
    puts Behavior::SysId.report(Behavior::SysId.analyse(tr, f, lambda_c: lam), verbose: vb)
    puts
  end
end
