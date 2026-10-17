# Historical PingStat / MacNetStatus bundle identifiers (source with: source scripts/lib/legacy-bundle-ids.sh)
# macOS 26 Menu Bar lists each bundle ID separately even when the display name is "PingStat".
PINGSTAT_LEGACY_BUNDLE_IDS=(
  org.malcomvetter.PingStat
  org.malcomvetter.PingStatTests
  dev.malcomvetter.PingStat
  dev.malcomvetter.PingStatTests
  com.example.PingStat
  com.example.PingStatTests
  com.example.MacNetStatus
  com.example.MacNetStatusTests
)

# Substrings used when scrubbing Control Center / preference keys.
PINGSTAT_LEGACY_KEY_SUBSTRINGS=(
  pingstat
  macnetstatus
  org.malcomvetter
  dev.malcomvetter
  com.example
)
