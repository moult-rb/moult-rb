# frozen_string_literal: true

class Dispatcher
  def run(name)
    send(name)
  end

  def dynamic_target
    :reachable_via_send
  end
end
