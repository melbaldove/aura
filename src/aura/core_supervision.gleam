import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision

/// The dependency-ordered child specifications for Aura core roles.
pub type CoreChildren {
  CoreChildren(
    database: supervision.ChildSpecification(Nil),
    cognitive_delivery: supervision.ChildSpecification(Nil),
    cognitive_worker: supervision.ChildSpecification(Nil),
    event_ingest: supervision.ChildSpecification(Nil),
    external_asks: supervision.ChildSpecification(Nil),
    flare_manager: supervision.ChildSpecification(Nil),
    channel_supervisor: supervision.ChildSpecification(Nil),
    brain: supervision.ChildSpecification(Nil),
    scheduler: supervision.ChildSpecification(Nil),
  )
}

fn stop_service_on_failure(
  child: supervision.ChildSpecification(Nil),
) -> supervision.ChildSpecification(Nil) {
  child
  |> supervision.restart(supervision.Temporary)
  |> supervision.significant(True)
}

/// Build the restart tree for Aura core roles.
///
/// Stateless roles restart independently through stable process names. A role
/// that owns unlinked work or in-memory waiters stops the service on failure.
pub fn builder(children: CoreChildren) -> static_supervisor.Builder {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.restart_tolerance(intensity: 20, period: 60)
  |> static_supervisor.auto_shutdown(static_supervisor.AnySignificant)
  |> static_supervisor.add(children.database)
  |> static_supervisor.add(children.cognitive_delivery)
  |> static_supervisor.add(children.cognitive_worker)
  |> static_supervisor.add(children.event_ingest)
  |> static_supervisor.add(stop_service_on_failure(children.external_asks))
  |> static_supervisor.add(stop_service_on_failure(children.flare_manager))
  |> static_supervisor.add(stop_service_on_failure(children.channel_supervisor))
  |> static_supervisor.add(children.brain)
  |> static_supervisor.add(stop_service_on_failure(children.scheduler))
}

/// Start the restart tree for Aura core roles.
pub fn start(
  children: CoreChildren,
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  children
  |> builder
  |> static_supervisor.start
}

/// Build a child specification for the Aura root supervisor.
pub fn supervised(children: CoreChildren) -> supervision.ChildSpecification(Nil) {
  children
  |> builder
  |> static_supervisor.supervised
  |> supervision.map_data(fn(_) { Nil })
  |> supervision.restart(supervision.Temporary)
  |> supervision.significant(True)
}
