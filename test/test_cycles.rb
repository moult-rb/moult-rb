# frozen_string_literal: true

require "test_helper"

# Pure unit tests for the cycles analysis: hand-built {Index::Edge} lists in,
# {CyclesReport} out. No rubydex — the live edge extraction is covered by
# test_index.rb and test_cycles_cli.rb.
class TestCycles < Minitest::Test
  def edge(src, dst, line: 1)
    Moult::Index::Edge.new(
      src: src, dst: dst, constant: "X",
      span: Moult::Span.new(start_line: line, start_column: 0, end_line: line, end_column: 5)
    )
  end

  def build(edges)
    Moult::Cycles.build_report(root: "/x", edges: edges)
  end

  def cyclic_edges
    [
      edge("a.rb", "b.rb"), edge("b.rb", "a.rb"), # 2-cycle
      edge("x.rb", "y.rb"), edge("y.rb", "z.rb"), edge("z.rb", "x.rb"), # 3-cycle
      edge("solo.rb", "a.rb") # acyclic in-edge into the 2-cycle
    ]
  end

  def test_detects_cycles_largest_first
    report = build(cyclic_edges)
    assert_equal 2, report.findings.size
    assert_equal %w[x.rb y.rb z.rb], report.findings[0].files
    assert_equal 3, report.findings[0].size
    assert_equal %w[a.rb b.rb], report.findings[1].files
  end

  def test_acyclic_graph_has_no_findings
    report = build([edge("a.rb", "b.rb"), edge("b.rb", "c.rb"), edge("a.rb", "c.rb")])
    assert_empty report.findings
    assert_equal({cycles: 0, files: 0, largest: 0}, report.summary)
  end

  def test_evidence_edges_restricted_to_cycle_members
    finding = build(cyclic_edges).findings[1]
    assert_equal [%w[a.rb b.rb], %w[b.rb a.rb]], finding.edges.map { |e| [e.src, e.dst] }
  end

  def test_cycle_group_stable_under_edge_order
    groups = build(cyclic_edges).findings.map(&:cycle_group)
    shuffled = build(cyclic_edges.shuffle(random: Random.new(42))).findings.map(&:cycle_group)
    assert_equal groups, shuffled
    assert(groups.all? { |g| g.start_with?("scc:") })
  end

  def test_self_edge_alone_is_not_a_cycle
    assert_empty build([edge("a.rb", "a.rb")]).findings
  end

  def test_summary_counts
    assert_equal({cycles: 2, files: 5, largest: 3}, build(cyclic_edges).summary)
  end

  def test_findings_carry_confidence_and_reason
    finding = build(cyclic_edges).findings.first
    assert_equal 0.9, finding.confidence
    assert_equal "cycle", finding.category
    assert_equal [:resolved_constant_edges], finding.reasons.map(&:rule)
  end

  # Pins the iterative Tarjan choice: stdlib TSort's recursive SCC walk
  # SystemStackErrors on cycles this deep.
  def test_ten_thousand_node_cycle_completes
    n = 10_000
    edges = (0...n).map { |i| edge("f#{i}.rb", "f#{(i + 1) % n}.rb") }
    report = build(edges)
    assert_equal 1, report.findings.size
    assert_equal n, report.findings.first.size
  end
end
