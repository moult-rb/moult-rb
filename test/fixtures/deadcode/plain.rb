# frozen_string_literal: true

class Calculator
  def used_add(a, b)
    a + b
  end

  def unused_subtract(a, b)
    a - b
  end

  def only_tested(a)
    a
  end

  private

  def dead_helper
    :unused
  end
end
