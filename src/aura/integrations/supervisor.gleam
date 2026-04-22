//// Supervises all configured integrations under a `OneForOne` inner
//// supervisor. Each `[[integrations]]` block in config becomes one
//// supervised child, isolated from siblings — a Gmail IMAP disconnect
//// storm can't take down a Linear listener.
////
//// Dispatches on the `IntegrationConfig` variant to the matching
//// per-integration `supervised` constructor. For phase 1.5 that's only
//// `GmailIntegration` → `gmail.supervised/2`; new integrations slot in
//// here by adding a variant to `config.IntegrationConfig` and a case
//// arm below.

import aura/config
import aura/event_ingest
import aura/integrations/gmail
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/static_supervisor
import gleam/otp/supervision

/// Build a child spec that, when started, supervises every configured
/// integration. Empty `integrations` config starts a supervisor with no
/// children — valid and non-fatal.
pub fn supervised(
  integrations_config: config.IntegrationsConfig,
  event_ingest_subject: Subject(event_ingest.IngestMessage),
) -> supervision.ChildSpecification(Nil) {
  static_supervisor.supervised(builder(
    integrations_config,
    event_ingest_subject,
  ))
  |> supervision.map_data(fn(_) { Nil })
}

/// Build the inner supervisor's builder. Exposed so tests can start it
/// directly and observe the pid; production goes through `supervised/2`.
pub fn builder(
  integrations_config: config.IntegrationsConfig,
  event_ingest_subject: Subject(event_ingest.IngestMessage),
) -> static_supervisor.Builder {
  let config.IntegrationsConfig(integrations) = integrations_config
  list.fold(
    integrations,
    static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.restart_tolerance(intensity: 10, period: 60),
    fn(b, integration) {
      static_supervisor.add(b, child_for(integration, event_ingest_subject))
    },
  )
}

fn child_for(
  integration: config.IntegrationConfig,
  event_ingest_subject: Subject(event_ingest.IngestMessage),
) -> supervision.ChildSpecification(_) {
  case integration {
    config.GmailIntegration(config: gmail_cfg) ->
      gmail.supervised(gmail_cfg, event_ingest_subject)
      |> supervision.map_data(fn(_) { Nil })
  }
}
