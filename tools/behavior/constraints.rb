# Check a proposed cyclic counter using observed transitions and, optionally,
# Z3. The bit-vector expression models machine-width wrap rather than Ruby's
# unbounded integers. This is a small explicit constraint checker, not a claim
# that arbitrary game logic has been solved.
require_relative "trace"
require "open3"

module Behavior
  module Constraints
    def self.parse_integer(v)
      return v if v.is_a?(Integer)
      return v.to_i if v.is_a?(Float) && v == v.to_i
      return Integer(v, 10) if v.is_a?(String) && v.match?(/\A[+-]?\d+\z/)
      nil
    end

    def self.check_counter(trace, field, width:, modulus:)
      raise "width must be 1..64" unless (1..64).cover?(width)
      capacity = 1 << width
      raise "modulus must be 2..2^width" unless (2..capacity).cover?(modulus)
      violations = []
      checked = 0
      trace.samples.each_cons(2) do |a, b|
        next unless b.t == a.t + 1
        q = parse_integer(a.x[Trace.normalize_key(field)])
        n = parse_integer(b.x[Trace.normalize_key(field)])
        next if q.nil? || n.nil?
        checked += 1
        expected = (q + 1) % modulus
        violations << { from_t: a.t, q: q, observed: n, expected: expected,
                        reason: (q.negative? || q >= modulus || n.negative? || n >= modulus) ? "outside range" : "recurrence mismatch" } if n != expected || q.negative? || q >= modulus || n.negative? || n >= modulus
      end
      { width: width, modulus: modulus, checked: checked, violations: violations }
    end

    def self.smt2(trace, field, width:, modulus:)
      rows = trace.samples.each_cons(2).select { |a, b| b.t == a.t + 1 }
      mask = (1 << width) - 1
      bv = ->(n) { "(_ bv#{n & mask} #{width})" }
      lines = ["(set-logic QF_BV)"]
      declared = {}
      rows.each_with_index do |(a, b), i|
        q = parse_integer(a.x[Trace.normalize_key(field)])
        n = parse_integer(b.x[Trace.normalize_key(field)])
        next if q.nil? || n.nil?
        [i, i + 1].each do |j|
          next if declared[j]
          lines << "(declare-const q#{j} (_ BitVec #{width}))"
          declared[j] = true
        end
        lines << "(assert (= q#{i} #{bv.call(q)}))"
        lines << "(assert (= q#{i + 1} #{bv.call(n)}))"
        if modulus == (1 << width)
          lines << "(assert (= q#{i + 1} (bvadd q#{i} #{bv.call(1)})))"
        else
          lines << "(assert (bvult q#{i} #{bv.call(modulus)}))"
          lines << "(assert (bvult q#{i + 1} #{bv.call(modulus)}))"
          lines << "(assert (= q#{i + 1} (ite (= q#{i} #{bv.call(modulus - 1)}) #{bv.call(0)} (bvadd q#{i} #{bv.call(1)}))))"
        end
      end
      lines << "(check-sat)"
      lines.join("\n") + "\n"
    end

    def self.find_z3(explicit = nil)
      candidates = [explicit, ENV["Z3_EXE"]].compact
      path_exts = (ENV["PATHEXT"] || ".EXE;.CMD;.BAT").split(";")
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        candidates.concat(path_exts.map { |ext| File.join(dir, "z3#{ext.downcase}") })
        candidates << File.join(dir, "z3")
      end
      candidates.find { |p| File.file?(p) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  def value(name, fallback = nil)
    i = ARGV.index("--#{name}")
    i && ARGV[i + 1] && !ARGV[i + 1].start_with?("--") ? ARGV[i + 1] : fallback
  end
  file = ARGV.find { |a| !a.start_with?("--") }
  unless file && value("field") && value("width") && value("modulus")
    warn "usage: ruby constraints.rb <trace.jsonl> --field 48 --width 8 --modulus 256 [--z3 path] [--emit model.smt2]"
    exit 2
  end
  tr = Behavior::Trace.load(file)
  field, width, mod = value("field"), value("width").to_i, value("modulus").to_i
  report = Behavior::Constraints.check_counter(tr, field, width: width, modulus: mod)
  formula = Behavior::Constraints.smt2(tr, field, width: width, modulus: mod)
  if (out = value("emit"))
    File.write(out, formula)
    puts "SMT-LIB written to #{out}"
  end
  z3 = Behavior::Constraints.find_z3(value("z3"))
  if z3
    stdout, stderr, status = Open3.capture3(z3, "-smt2", "-in", stdin_data: formula)
    puts "Z3: #{stdout.strip}#{stderr.empty? ? '' : " (#{stderr.strip})"}"
    unless status.success?
      warn "Z3 execution failed; direct observed-transition result follows."
    end
  else
    puts "Z3 not found; using direct observed-transition check (set Z3_EXE or pass --z3 for solver-backed constraints)."
  end
  puts "field +0x#{Behavior::Trace.normalize_key(field)}: #{report[:checked]} consecutive transitions, width #{width}, modulo #{mod}"
  if report[:violations].empty?
    if report[:checked].zero?
      puts "no usable integer transitions; the hypothesis is untested"
      exit 1
    end
    puts "observed transitions are consistent with the proposed recurrence"
  else
    puts "COUNTEREXAMPLES:"
    report[:violations].each { |v| puts "  t=#{v[:from_t]} q=#{v[:q]} -> observed #{v[:observed]}, expected #{v[:expected]} (#{v[:reason]})" }
    exit 1
  end
end
