# frozen_string_literal: true

# Alpha and Beta share a byte-identical #normalize method (an IDENTICAL clone),
# but the surrounding classes differ in their other members so the class nodes
# themselves are not duplicated — that keeps flay reporting at the :defn level,
# where the clone attributes cleanly to an enclosing method's symbol_id.
class Alpha
  def label
    "alpha"
  end

  def normalize(values)
    acc = []
    values.each do |v|
      acc << v.to_s.strip.downcase
      acc << v.hash.to_s
    end
    acc.join("-")
  end
end
