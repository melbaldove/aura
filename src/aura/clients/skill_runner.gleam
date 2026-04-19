//// Dependency-injected skill runner. Wraps `skill.invoke` so tests can
//// substitute scripted skill results via `test/fakes/fake_skill_runner.new()`
//// (later tasks).

import aura/skill

pub type SkillRunner {
  SkillRunner(
    invoke: fn(skill.SkillInfo, List(String), Int) ->
      Result(skill.SkillResult, String),
  )
}

pub fn production() -> SkillRunner {
  SkillRunner(invoke: skill.invoke)
}
