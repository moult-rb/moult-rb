# frozen_string_literal: true

require "digest"

module Moult
  # File-level circular dependencies over the {Index#file_edges} graph. Every
  # edge is a *resolved* constant reference — the only dependency signal that
  # survives Zeitwerk autoloading, where `require` lines are absent — so each
  # cycle is backed by concrete reference sites, never name matching.
  module Cycles
    # High because every edge is a resolved constant reference, but not 1.0: a
    # constant reopened in several files fans its edges out to every definition
    # file, which can widen a cycle beyond the code that actually participates.
    CONFIDENCE = 0.9

    CATEGORY = "cycle"

    module_function

    # @param root [String] absolute analysis root
    # @param edges [Array<Index::Edge>] file dependency edges
    # @return [CyclesReport] findings ranked largest cycle first
    def build_report(root:, edges:, git_ref: nil, generated_at: nil,
      backend_version: nil, resolved: true, diagnostics: [])
      components = strongly_connected(adjacency(edges))
      findings = components.select { |c| c.size >= 2 }.map { |c| finding_for(c, edges) }
      findings.sort_by! { |f| [-f.size, f.files.first] }
      CyclesReport.new(
        root: root, findings: findings, git_ref: git_ref, generated_at: generated_at,
        backend: "rubydex", backend_version: backend_version,
        resolved: resolved, diagnostics: diagnostics
      )
    end

    # Sorted node => sorted children over every file named by an edge, so the
    # SCC walk (and therefore the report) is deterministic regardless of the
    # order edges arrive in.
    def adjacency(edges)
      adj = {}
      edges.each do |edge|
        (adj[edge.src] ||= []) << edge.dst
        adj[edge.dst] ||= []
      end
      adj.keys.sort.to_h { |node| [node, adj[node].uniq.sort] }
    end

    # Tarjan's strongly-connected components with an explicit work stack.
    # ponytail: hand-rolled because stdlib TSort's SCC walk is recursive and
    # SystemStackErrors on cycles a few thousand files deep (measured at ~5k);
    # swap back to TSort if it ever gains an iterative walker.
    def strongly_connected(adj)
      index = {}
      lowlink = {}
      on_stack = {}
      stack = []
      components = []
      counter = 0

      adj.each_key do |start|
        next if index.key?(start)
        work = [[start, 0]]
        until work.empty?
          frame = work.last
          node = frame[0]
          if frame[1].zero? # first visit
            index[node] = lowlink[node] = counter
            counter += 1
            stack << node
            on_stack[node] = true
          end

          children = adj[node]
          pushed = false
          while frame[1] < children.size
            child = children[frame[1]]
            frame[1] += 1
            if !index.key?(child)
              work << [child, 0]
              pushed = true
              break
            elsif on_stack[child]
              lowlink[node] = [lowlink[node], index[child]].min
            end
          end
          next if pushed

          work.pop
          if lowlink[node] == index[node]
            component = []
            loop do
              member = stack.pop
              on_stack.delete(member)
              component << member
              break if member == node
            end
            components << component
          end
          parent = work.last&.first
          lowlink[parent] = [lowlink[parent], lowlink[node]].min if parent
        end
      end
      components
    end

    def finding_for(component, edges)
      files = component.sort
      member = component.to_h { |f| [f, true] }
      evidence = edges.select { |e| member[e.src] && member[e.dst] && e.src != e.dst }
        .sort_by { |e| [e.src, e.dst] }
      CyclesReport::Finding.new(
        cycle_group: fingerprint(files),
        confidence: CONFIDENCE,
        category: CATEGORY,
        size: files.size,
        files: files,
        reasons: [Confidence::Reason.new(
          rule: :resolved_constant_edges,
          delta: CONFIDENCE,
          detail: "every edge is a resolved constant reference; reopened constants can widen a cycle"
        )],
        edges: evidence
      )
    end

    # Membership-stable across runs and machines (unlike a detector-backend
    # hash): the same set of files is the same cycle, however its edges shift.
    def fingerprint(files)
      "scc:#{Digest::SHA256.hexdigest(files.join("\n"))[0, 12]}"
    end
  end
end
