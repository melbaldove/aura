import aura/acp/report
import aura/acp/types
import gleeunit/should

pub fn parse_report_clean_test() {
  let output =
    "Output...\n\n---AURA-REPORT---\nOUTCOME: clean\nFILES_CHANGED: src/ack.rs, src/tests/ack_test.rs\nDECISIONS: Used separate format\nTESTS: 12 passed, 0 failed\nBLOCKERS: none\nANCHOR: Return files use separate ACK format\n---END-REPORT---"
  let r = report.parse(output) |> should.be_ok
  r.outcome |> should.equal(types.Clean)
  r.anchor |> should.equal("Return files use separate ACK format")
}

pub fn parse_report_partial_test() {
  let output =
    "---AURA-REPORT---\nOUTCOME: partial\nFILES_CHANGED: src/main.rs\nDECISIONS: Started fix\nTESTS: 8 passed, 2 failed\nBLOCKERS: Missing fixture\nANCHOR: Fix incomplete\n---END-REPORT---"
  let r = report.parse(output) |> should.be_ok
  r.outcome |> should.equal(types.Partial)
}

pub fn parse_report_missing_test() {
  report.parse("No report here") |> should.be_error
}

pub fn parse_report_failed_test() {
  let output =
    "---AURA-REPORT---\nOUTCOME: failed\nFILES_CHANGED: none\nDECISIONS: Could not reproduce\nTESTS: not run\nBLOCKERS: Cannot reproduce\nANCHOR: Bug may be env-specific\n---END-REPORT---"
  let r = report.parse(output) |> should.be_ok
  r.outcome |> should.equal(types.Failed)
}
