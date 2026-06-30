# frozen_string_literal: true

class Beta
  def normalize(values)
    acc = []
    values.each do |v|
      acc << v.to_s.strip.downcase
      acc << v.hash.to_s
    end
    acc.join("-")
  end

  def kind
    :beta
  end

  def combine(a, b)
    a + b
  end
end
