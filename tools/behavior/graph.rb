# Dependency graphs for static code, runtime memory, and observed behavior.
# JSON input keeps claims explicit: an edge is evidence of one relation, not
# proof that adjacent addresses form a C++ object.
require "json"
require "set"

module Behavior
  class InfluenceGraph
    EDGE_TYPES = %w[calls reads writes transitions controls influences].freeze
    attr_reader :nodes, :edges

    def initialize(doc)
      raw_nodes = doc.fetch("nodes") { raise "graph needs a nodes array" }
      raise "nodes must be an array" unless raw_nodes.is_a?(Array)
      @nodes = raw_nodes.to_h do |n|
        id = n.fetch("id").to_s
        [id, n]
      end
      raise "duplicate node ids" unless @nodes.size == raw_nodes.size
      @edges = doc.fetch("edges", []).map do |e|
        type = e.fetch("type", "influences").to_s
        raise "unknown edge type #{type}" unless EDGE_TYPES.include?(type)
        from, to = e.fetch("from").to_s, e.fetch("to").to_s
        raise "edge references missing node: #{from} -> #{to}" unless @nodes.key?(from) && @nodes.key?(to)
        e.merge("from" => from, "to" => to, "type" => type)
      end
    end

    def self.load(path) = new(JSON.parse(File.read(path)))

    def slice(seeds, direction: :backward, kinds: nil, depth: nil)
      raise "direction must be backward or forward" unless %i[backward forward].include?(direction)
      seeds = Array(seeds).map(&:to_s)
      missing = seeds.reject { |id| @nodes.key?(id) }
      raise "unknown seed node(s): #{missing.join(', ')}" unless missing.empty?
      allowed = kinds && Array(kinds).map(&:to_s)
      selected = seeds.to_set
      frontier = seeds.map { |id| [id, 0] }
      used_edges = []
      until frontier.empty?
        id, d = frontier.shift
        next if depth && d >= depth
        adjacent = @edges.select do |e|
          (direction == :backward ? e["to"] == id : e["from"] == id) && (!allowed || allowed.include?(e["type"]))
        end
        adjacent.each do |e|
          other = direction == :backward ? e["from"] : e["to"]
          used_edges << e
          next if selected.include?(other)
          selected << other
          frontier << [other, d + 1]
        end
      end
      { "direction" => direction.to_s, "seeds" => seeds,
        "nodes" => selected.map { |id| @nodes.fetch(id) },
        "edges" => used_edges.uniq }
    end

    # Iterative Cooper-style set algorithm. Restrict to one function's CFG;
    # dataflow edges must not be mixed into control-flow dominators.
    def cfg(function:, entry: nil)
      fn_nodes = @nodes.values.select { |n| n["function"].to_s == function.to_s }
      ids = fn_nodes.map { |n| n.fetch("id").to_s }.to_set
      raise "no nodes for function #{function}" if ids.empty?
      entries = entry ? [entry.to_s] : fn_nodes.select { |n| n["entry"] }.map { |n| n["id"].to_s }
      entries = [ids.first] if entries.empty?
      raise "entry outside function: #{entries - ids.to_a}" unless (entries.to_set - ids).empty?
      ce = @edges.select { |e| e["type"] == "controls" && ids.include?(e["from"]) && ids.include?(e["to"]) }
      preds = ids.to_h { |id| [id, ce.select { |e| e["to"] == id }.map { |e| e["from"] }] }
      dom = ids.to_h { |id| [id, entries.include?(id) ? Set[id] : ids.dup] }
      changed = true
      while changed
        changed = false
        ids.each do |id|
          next if entries.include?(id)
          ps = preds[id]
          common = ps.empty? ? Set.new : ps.map { |p| dom[p] }.reduce(&:intersection)
          value = common | [id]
          if value != dom[id]
            dom[id] = value
            changed = true
          end
        end
      end
      backs = ce.select { |e| dom.fetch(e["from"]).include?(e["to"]) }
      loops = backs.map do |edge|
        header, tail = edge.values_at("to", "from")
        body = Set[header, tail]
        work = tail == header ? [] : [tail]
        until work.empty?
          n = work.pop
          preds.fetch(n, []).each do |p|
            next if body.include?(p)
            body << p
            work << p unless entries.include?(p)
          end
        end
        { "back_edge" => [tail, header], "header" => header, "nodes" => body.to_a.sort }
      end
      { "function" => function.to_s, "entries" => entries,
        "dominators" => dom.transform_values { |s| s.to_a.sort },
        "back_edges" => backs.map { |e| [e["from"], e["to"]] }, "natural_loops" => loops }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  def usage
    warn <<~TXT
      usage:
        ruby graph.rb slice <graph.json> backward|forward <node-id> [--kind reads,writes] [--depth N]
        ruby graph.rb cfg <graph.json> <function-id> [--entry node-id]
      JSON schema: {"nodes":[{"id":"...","kind":"instruction|function|memory|state","function":"...","entry":true}],
                    "edges":[{"from":"...","to":"...","type":"calls|reads|writes|transitions|controls"}]}
      A static call/read/write edge is a candidate influence, not runtime proof.
    TXT
    exit 2
  end
  usage if ARGV.size < 3
  command, file, arg = ARGV
  g = Behavior::InfluenceGraph.load(file)
  result = if command == "slice"
    direction, seed = ARGV[2], ARGV[3]
    usage unless %w[backward forward].include?(direction) && seed
    k = ARGV.each_cons(2).find { |a, _| a == "--kind" }&.last&.split(",")
    d = ARGV.each_cons(2).find { |a, _| a == "--depth" }&.last&.to_i
    g.slice(seed, direction: direction.to_sym, kinds: k, depth: d && d.positive? ? d : nil)
  elsif command == "cfg"
    usage unless arg
    en = ARGV.each_cons(2).find { |a, _| a == "--entry" }&.last
    g.cfg(function: arg, entry: en)
  else
    usage
  end
  puts JSON.pretty_generate(result)
end
