# frozen_string_literal: false

def make_query(text:, mode:, model:, reasoning_effort:,
               first_language:, second_language:,
               emoji:, max_tokens:, temperature:, frequency_penalty:,
               presence_penalty:, top_p:, speak:)

  case mode
  when "chat", "vision"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => text,
      "max_tokens" => max_tokens,
      "temperature" => temperature,
      "frequency_penalty" => frequency_penalty,
      "presence_penalty" => presence_penalty,
      "top_p" => top_p
    }
  when "text"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => text,
      "max_tokens" => max_tokens,
      "temperature" => temperature,
      "frequency_penalty" => frequency_penalty,
      "presence_penalty" => presence_penalty,
      "top_p" => top_p
    }
  when "general"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => text,
      "max_tokens" => max_tokens,
      "temperature" => temperature,
      "frequency_penalty" => frequency_penalty,
      "presence_penalty" => presence_penalty,
      "top_p" => top_p
    }
  when "write_program_code"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "#{text}\n\nReturn the response program code and examples all in a strictly valid markdown format",
      "max_tokens" => max_tokens,
      "temperature" => 0.0,
      "frequency_penalty" => 0,
      "presence_penalty" => 0,
      "top_p" => 1.0
    }
  when "question_in_your_language"
    if first_language.to_s == ""
      print "❗️ ERROR: variable your_first_language not specified"
      exit 1
    end
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "Answer the question in #{first_language} below using #{first_language}:\n\n" + "Q: #{text}\n\nA: ",
      "max_tokens" => max_tokens,
      "temperature" => 0.0,
      "frequency_penalty" => 0,
      "presence_penalty" => 0,
      "top_p" => 1.0
    }
  when "translate_l1_to_l2"
    if first_language.to_s == "" || second_language.to_s == ""
      print "❗️ ERROR: variables your_first_language and your_second_language not specified"
      exit 1
    end
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "Translate this #{first_language} text to #{second_language}:\n\n" + text,
      "max_tokens" => max_tokens,
      "temperature" => 0.3,
      "frequency_penalty" => 0,
      "presence_penalty" => 0,
      "top_p" => 1.0
    }
  when "translate_l2_to_l1"
    if first_language.to_s == "" || second_language.to_s == ""
      print "❗️ ERROR: variables your_first_language and your_second_language not specified"
      exit 1
    end
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "Translate this #{second_language} text to #{first_language}:\n\n" + text,
      "max_tokens" => max_tokens,
      "temperature" => 0.3,
      "frequency_penalty" => 0,
      "presence_penalty" => 0,
      "top_p" => 1.0
    }
  when "summarization"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "Summarize the folloing text:\n\n#{text}",
      "max_tokens" => max_tokens,
      "temperature" => 0.7,
      "frequency_penalty" => 0,
      "presence_penalty" => 0,
      "top_p" => 1.0
    }
  when "analogy_maker"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "Create an analogy for this phrase:\n\n#{text}",
      "max_tokens" => max_tokens,
      "temperature" => 0,
      "frequency_penalty" => 0,
      "presence_penalty" => 0,
      "top_p" => 1.0
    }
  when "essay_outline"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "Create an outline for an essay about #{text}?",
      "max_tokens" => max_tokens,
      "temperature" => 0,
      "frequency_penalty" => 0,
      "presence_penalty" => 0,
      "top_p" => 1.0
    }
  when "create_study_notes"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "What are 5 key points I should know when studying #{text}?",
      "max_tokens" => max_tokens,
      "temperature" => 0.3,
      "frequency_penalty" => 0,
      "presence_penalty" => 0,
      "top_p" => 1.0
    }
  when "q_and_a"
    prompt = <<~PRNPT
      I am a highly intelligent question answering bot.
      If you ask me a question that is rooted in truth,
      I will give you the answer. If you ask me a question
      that is nonsense, trickery, or has no clear answer,
      I will respond with 'Unknown'.\n\nQ: #{text}
    PRNPT
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => prompt,
      "temperature" => 0,
      "max_tokens" => max_tokens,
      "frequency_penalty" => 0,
      "presence_penalty" => 0,
      "top_p" => 1.0
    }
  when "grammar_correction"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "Correct this to standard English:\n\n#{text}",
      "max_tokens" => max_tokens,
      "temperature" => 0,
      "frequency_penalty" => 0,
      "presence_penalty" => 0,
      "top_p" => 1.0
    }
  when "summarize_for_a_2nd_grader"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "Summarize this for a second-grade student:\n\n#{text}",
      "max_tokens" => max_tokens,
      "temperature" => 0.7,
      "frequency_penalty" => 0.0,
      "presence_penalty" => 0.0,
      "top_p" => 1.0
    }
  when "brainstorm"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "Brainstorm some ideas about #{text}",
      "max_tokens" => max_tokens,
      "temperature" => 0.6,
      "frequency_penalty" => 0.0,
      "presence_penalty" => 0.0,
      "top_p" => 1.0
    }
  when "keywords"
    query = {
      "model" => model,
      "reasoning_effort" => reasoning_effort,
      "prompt" => "Extract keywords from this text:\n\n#{text}",
      "max_tokens" => max_tokens,
      "temperature" => 0.3,
      "frequency_penalty" => 0.8,
      "presence_penalty" => 0.0,
      "top_p" => 1.0
    }
  end
  query["emoji"] = emoji
  query["speak"] = speak

  query
end
