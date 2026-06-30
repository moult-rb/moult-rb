# frozen_string_literal: true

require "json"
require "time"

module Moult
  module Flags
    # Ingests a LOCAL OpenFeature provider flag-state export and normalises it into
    # one Moult-owned value object ({FlagSet}) the {Staleness} model can read. This is
    # the flags analogue of {Coverage} (which ingests a SimpleCov/stdlib dump) and of
    # {Boundaries::Packwerk} (which ingests packwerk's committed artifacts): an
    # external format comes in, only Moult types go out, so the provider is swappable
    # and nothing downstream depends on its on-disk shape.
    #
    # One on-disk format is understood today (auto-detected, or forced via +format:+):
    #
    # * +:flagd+ — a flagd flag-definition JSON, the OpenFeature-native provider-
    #   agnostic representation of flag state:
    #   <tt>{"flags" => {key => {"state" => "ENABLED"|"DISABLED", "variants" => {...},
    #   "defaultVariant" => "...", "targeting" => {...}, "metadata" => {...}}},
    #   "metadata" => {...}}</tt>.
    #
    # flagd quirks normalised HERE and nowhere else (the swap point for a future
    # provider/standard):
    #
    # * +state+ "ENABLED"/"DISABLED" maps to +enabled+ true/false.
    # * A non-empty +targeting+ object means the flag serves more than the default
    #   variant; an empty/absent one means it is fully rolled out to one variant.
    # * flagd has no native archival/lifecycle state, so it is read from the standard
    #   per-flag +metadata+ extension point: +metadata.archived == true+, or
    #   +metadata.lifecycle+ in {"archived", "deprecated"}.
    # * Timestamps (+metadata.updatedAt+/+lastModified+ per flag; the flag-set
    #   +metadata+ export stamp) are captured as evidence only; the live, streaming
    #   provider connection that would make them authoritative is deferred, exactly
    #   like the live Coverband store.
    #
    # This adapter takes NO dependency on the +openfeature-sdk+ or any vendor SDK; it
    # reads the export with stdlib JSON, mirroring how {Coverage} needs no simplecov
    # and {Boundaries::Packwerk} no packwerk gem.
    module Snapshot
      module_function

      # Provenance of a merged provider snapshot. Captured into the protected
      # contract (analysis.provider) so a consumer can see where the staleness
      # evidence came from. +exported_at+ also seeds the deferred time-decay slice.
      Source = Struct.new(:backend, :version, :exported_at) do
        def to_h
          {backend: backend, version: version, exported_at: exported_at}
        end
      end

      # The provider's normalised state for one flag key. +enabled+/+archived+/
      # +has_targeting+ are the facts {Staleness} judges; +default_variant+ and
      # +updated_at+ are captured for context and the deferred time-decay seed.
      FlagState = Struct.new(:key, :enabled, :archived, :has_targeting, :default_variant, :updated_at)

      # A normalised snapshot: the provider's state per flag key, plus provenance.
      FlagSet = Struct.new(:states, :source) do
        # @return [Boolean] whether the provider knows this key
        def key?(flag_key)
          states.key?(flag_key)
        end

        # @return [FlagState, nil] the provider's state for the key, or nil if absent
        def state_for(flag_key)
          states[flag_key]
        end
      end

      ARCHIVED_LIFECYCLES = %w[archived deprecated].freeze

      # @param path [String] path to the provider snapshot file
      # @param format [Symbol] :auto (default) or :flagd
      # @return [FlagSet]
      def load(path, format: :auto)
        raw = JSON.parse(File.read(path))
        fmt = (format == :auto) ? detect_format(raw) : format
        case fmt
        when :flagd then from_flagd(raw, path)
        else raise Moult::Error, "unknown provider snapshot format: #{fmt}"
        end
      rescue JSON::ParserError => e
        raise Moult::Error, "could not parse provider snapshot #{path}: #{e.message}"
      rescue Errno::ENOENT
        raise Moult::Error, "no such provider snapshot: #{path}"
      end

      # A flagd export is a JSON object with a top-level "flags" map whose every
      # entry carries a "state" — the unambiguous discriminator.
      def detect_format(raw)
        raise Moult::Error, "provider snapshot is not a JSON object" unless raw.is_a?(Hash)
        flags = raw["flags"]
        if flags.is_a?(Hash) && flags.values.all? { |f| f.is_a?(Hash) && f.key?("state") }
          :flagd
        else
          raise Moult::Error, "could not auto-detect provider snapshot format; pass --provider-format flagd"
        end
      end

      # @return [FlagSet]
      def from_flagd(raw, path)
        flags = raw["flags"].is_a?(Hash) ? raw["flags"] : {}
        meta = raw["metadata"].is_a?(Hash) ? raw["metadata"] : {}
        states = flags.each_with_object({}) do |(key, defn), acc|
          acc[key] = flag_state(key, defn)
        end
        source = Source.new(
          backend: "flagd",
          version: stringify(meta["version"]),
          exported_at: snapshot_timestamp(meta, path)
        )
        FlagSet.new(states: states, source: source)
      end

      def flag_state(key, defn)
        defn = {} unless defn.is_a?(Hash)
        meta = defn["metadata"].is_a?(Hash) ? defn["metadata"] : {}
        FlagState.new(
          key: key,
          enabled: enabled?(defn["state"]),
          archived: archived?(meta),
          has_targeting: targeting?(defn["targeting"]),
          default_variant: defn["defaultVariant"],
          updated_at: stringify(meta["updatedAt"] || meta["lastModified"])
        )
      end

      # ENABLED/DISABLED -> true/false; any other (or missing) state -> nil, which
      # {Staleness} treats as neither rolled-out nor disabled (it falls through to
      # active rather than inventing a verdict).
      def enabled?(state)
        case state.to_s.upcase
        when "ENABLED" then true
        when "DISABLED" then false
        end
      end

      def archived?(meta)
        return true if meta["archived"] == true
        ARCHIVED_LIFECYCLES.include?(meta["lifecycle"].to_s.downcase)
      end

      def targeting?(targeting)
        targeting.is_a?(Hash) && !targeting.empty?
      end

      # Best-effort export stamp: an explicit flag-set metadata timestamp if present,
      # else the file mtime (noted only as a fallback; it seeds deferred time-decay).
      def snapshot_timestamp(meta, path)
        stamp = meta["exportedAt"] || meta["exported_at"] || meta["updatedAt"]
        return stringify(stamp) if stamp
        File.mtime(path).utc.iso8601
      rescue
        nil
      end

      def stringify(value)
        value&.to_s
      end
    end
  end
end
