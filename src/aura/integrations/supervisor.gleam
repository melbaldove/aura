//// Dynamic supervisor for integrations. Unlike static_supervisor, children
//// can be added at runtime — used when a user completes an in-chat OAuth
//// flow and we want the integration to start watching immediately, without
//// an AURA restart.
////
//// The supervisor registers under a fixed atom (`aura_integrations_sup`) via
//// factory_supervisor.named, so any tool or module can look it up via
//// `factory_supervisor.get_by_name(supervisor_name())` and issue
//// `start_child` calls.
////
//// Children are dispatched by IntegrationConfig variant. Initial children
//// declared in config.toml are bootstrapped after the root supervisor starts.

import aura/config
import aura/event_ingest
import aura/integrations/gmail
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/supervision
import gleam/string
import logging

pub type SupervisorMessage =
  factory_supervisor.Message(config.IntegrationConfig, Nil)

@external(erlang, "aura_integrations_ffi", "supervisor_name")
pub fn supervisor_name() -> Name(SupervisorMessage)

/// Build a supervised child spec for the root supervisor. Each call to
/// start_child later will invoke the template closure, which dispatches on
/// the IntegrationConfig variant to the right per-integration start fn.
///
/// The `event_ingest_subject` is captured in the template's closure and
/// shared by every integration the supervisor spawns.
pub fn supervised(
  event_ingest_subject: Subject(event_ingest.IngestMessage),
) -> supervision.ChildSpecification(
  factory_supervisor.Supervisor(config.IntegrationConfig, Nil),
) {
  factory_supervisor.worker_child(fn(integration: config.IntegrationConfig) {
    case integration {
      config.GmailIntegration(config: cfg) ->
        case gmail.start(cfg, event_ingest_subject) {
          Ok(started) -> Ok(actor.Started(pid: started.pid, data: Nil))
          Error(err) -> Error(err)
        }
    }
  })
  |> factory_supervisor.named(supervisor_name())
  |> factory_supervisor.restart_tolerance(intensity: 10, period: 60)
  |> factory_supervisor.supervised
}

/// Bootstrap initial integrations from the global config. Called after
/// root supervisor start so the factory supervisor is registered and the
/// template closure is live.
pub fn bootstrap(integrations_config: config.IntegrationsConfig) -> Nil {
  let config.IntegrationsConfig(integrations) = integrations_config
  list.each(integrations, fn(integration) {
    case start(integration) {
      Ok(_) -> Nil
      Error(err) -> {
        logging.log(
          logging.Error,
          "[integrations] bootstrap failed: " <> err,
        )
        Nil
      }
    }
  })
}

/// Start a new integration at runtime. Thin wrapper over
/// factory_supervisor.start_child — looks up the supervisor by its
/// registered name and dispatches via the template closure.
pub fn start(
  integration: config.IntegrationConfig,
) -> Result(Nil, String) {
  let sup = factory_supervisor.get_by_name(supervisor_name())
  case factory_supervisor.start_child(sup, integration) {
    Ok(_) -> Ok(Nil)
    Error(err) -> Error(string.inspect(err))
  }
}

/// Convenience wrapper: wrap a GmailConfig into an IntegrationConfig and
/// start it. Called from the connect_gmail_complete brain tool after a
/// successful OAuth exchange, so the Gmail integration starts watching
/// immediately without an AURA restart.
pub fn start_gmail(gmail_config: gmail.GmailConfig) -> Result(Nil, String) {
  start(config.GmailIntegration(config: gmail_config))
}
