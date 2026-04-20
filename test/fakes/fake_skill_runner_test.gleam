import aura/skill
import fakes/fake_skill_runner
import gleam/list
import gleeunit/should

fn fake_skill_info(name: String) -> skill.SkillInfo {
  skill.SkillInfo(name: name, description: "fake", path: "/tmp/fake")
}

pub fn fake_skill_runner_returns_scripted_result_test() {
  let #(fake, runner) = fake_skill_runner.new()
  fake_skill_runner.script_for(
    fake,
    "jira",
    skill.SkillResult(exit_code: 0, stdout: "ok", stderr: ""),
  )

  let result =
    runner.invoke(fake_skill_info("jira"), ["tickets", "assigned"], 5000)
  case result {
    Ok(sr) -> {
      sr.stdout |> should.equal("ok")
      sr.exit_code |> should.equal(0)
    }
    Error(_) -> should.fail()
  }
}

pub fn fake_skill_runner_records_invocations_test() {
  let #(fake, runner) = fake_skill_runner.new()
  fake_skill_runner.script_for(
    fake,
    "jira",
    skill.SkillResult(exit_code: 0, stdout: "", stderr: ""),
  )
  let _ = runner.invoke(fake_skill_info("jira"), ["arg1", "arg2"], 5000)

  let invocations = fake_skill_runner.invocations(fake)
  list.length(invocations) |> should.equal(1)
  case invocations {
    [first] -> {
      first.name |> should.equal("jira")
      first.args |> should.equal(["arg1", "arg2"])
    }
    _ -> should.fail()
  }
}

pub fn fake_skill_runner_unscripted_skill_returns_error_test() {
  let #(_fake, runner) = fake_skill_runner.new()
  let result = runner.invoke(fake_skill_info("unscripted"), [], 5000)
  case result {
    Error(reason) -> {
      case reason {
        "" -> should.fail()
        _ -> Nil
      }
    }
    Ok(_) -> should.fail()
  }
}
