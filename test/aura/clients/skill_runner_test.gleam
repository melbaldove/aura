import aura/clients/skill_runner

pub fn production_skill_runner_destructures_test() {
  case skill_runner.production() {
    skill_runner.SkillRunner(invoke: _) -> Nil
  }
}
