# Candidate field grouping from measured trajectories and optional access data.
# Similarity is a lead for investigation; correlated fields are not thereby one
# object or one semantic quantity.
require_relative "trace"
require_relative "graph"

module Behavior
  module Groups
    def self.correlation(a, b)
      pairs = a.zip(b).select { |x, y| !x.nil? && !y.nil? && x.is_a?(Numeric) && y.is_a?(Numeric) }
      return nil if pairs.size < 4
      xs, ys = pairs.transpose
      mx, my = Num.mean(xs), Num.mean(ys)
      xx = xs.sum { |x| (x - mx)**2 }; yy = ys.sum { |y| (y - my)**2 }
      return nil if xx.zero? || yy.zero?
      pairs.sum { |x, y| (x - mx) * (y - my) } / Math.sqrt(xx * yy)
    end

    def self.shared_access(graph, fields)
      return {} unless graph
      users = Hash.new { |h, k| h[k] = Set.new }
      graph.edges.each do |e|
        next unless %w[reads writes].include?(e["type"])
        a, b = graph.nodes[e["from"]], graph.nodes[e["to"]]
        mem = [a, b].compact.find { |n| n["kind"].to_s == "memory" || n.key?("field") }
        fn = [a, b].compact.find { |n| n["kind"].to_s == "function" }
        next unless mem && fn
        f = mem["field"]&.to_s&.downcase&.sub(/\A0x/, "")&.sub(/\A\+/, "")
        f ||= mem["id"].to_s.downcase[/\A(?:mem)?\+?0x?([0-9a-f]+)\z/, 1]
        f = Trace.normalize_key(f) if f
        field = fields.find { |key| key == f }
        users[field] << fn["id"].to_s if field
      end
      users
    end

    def self.analyse(trace, min_corr: 0.9, graph: nil)
      fields = trace.fields.select do |f|
        vals = trace.series(f).compact
        vals.size >= 4 && vals.all? { |v| v.is_a?(Numeric) }
      end
      pairs = []
      fields.combination(2) do |a, b|
        xs, ys = trace.series(a), trace.series(b)
        corr = correlation(xs, ys)
        next unless corr && corr.abs >= min_corr
        overlap = xs.zip(ys).count { |x, y| !x.nil? && !y.nil? }.to_f / [xs.size, ys.size].max
        access = shared_access(graph, [a, b])
        shared = access[a] && access[b] ? (access[a] & access[b]).to_a.sort : []
        pairs << { a: a, b: b, correlation: corr, overlap: overlap, shared_access: shared }
      end
      { fields: fields, pairs: pairs.sort_by { |p| -p[:correlation].abs }, graph: graph }
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
    warn "usage: ruby groups.rb <trace.jsonl> [--min-corr 0.9] [--graph graph.json]"
    exit 2
  end
  gr = value("graph") ? Behavior::InfluenceGraph.load(value("graph")) : nil
  result = Behavior::Groups.analyse(Behavior::Trace.load(file), min_corr: value("min-corr", "0.9").to_f, graph: gr)
  puts "numeric candidate fields: #{result[:fields].map { |f| "+0x#{f}" }.join(' ')}"
  if result[:pairs].empty?
    puts "no pairs passed the correlation threshold; vary movement, turning, and idle states before grouping"
  else
    result[:pairs].each do |p|
      puts format("+0x%s / +0x%s  correlation=%+.3f  co-observed=%.0f%%", p[:a], p[:b], p[:correlation], p[:overlap] * 100)
      puts "   shared read/write functions: #{p[:shared_access].join(', ')}" if p[:shared_access].any?
    end
  end
  puts "Interpretation: synchronized measurements are candidate groups only. Use shared access sites, allocation/lifetime evidence, and interventions before calling them object fields."
end
