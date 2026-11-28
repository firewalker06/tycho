# frozen_string_literal: true

module FocusLegacyBatchCases
  module_function

  def item(title, subtitle = nil)
    { "title" => title, "subtitle" => subtitle, "attachments" => [] }
  end

  def group(title, items)
    { "title" => title, "subtitle" => nil, "icon" => "note", "items" => items }
  end

  def cases
    long_title = "T" * 41
    long_subtitle = "S" * 61
    [
      { name: "crossed group names", limit: 40, field: "title",
        before: [group("One", [item("A" * 41)]), group("Two", [item("B" * 41)])],
        after: [group("Two", [item("A" * 41)]), group("One", [item("B" * 41)])] },
      { name: "crossed item names", limit: 60, field: "subtitle",
        before: [group("Work", [item("One", "A" * 61), item("Two", "B" * 61)])],
        after: [group("Work", [item("Two", "A" * 61), item("One", "B" * 61)])] },
      # All three destinations have two candidates. A greedy assignment can
      # consume the only remaining source of the third destination.
      { name: "overlapping group candidates", limit: 40, field: "title",
        before: [group("One", [item("X" * 41), item("Y" * 41)]), group("Two", [item("X" * 41)]), group("Three", [item("Y" * 41)])],
        after: [group("First", [item("X" * 41)]), group("Second", [item("Y" * 41)]), group("Third", [item("Y" * 41)])] },
      { name: "overlapping item candidates", limit: 40, field: "title",
        before: [group("Work", [item(long_title, long_subtitle), item(long_title), item("Old", long_subtitle)])],
        after: [group("Work", [item(long_title, "New"), item("New one", long_subtitle), item("New two", long_subtitle)])] }
    ]
  end
end
