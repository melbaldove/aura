//// Dependency-injected skill runner. Production wraps `skill.invoke`;
//// tests inject scripted fakes.

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
