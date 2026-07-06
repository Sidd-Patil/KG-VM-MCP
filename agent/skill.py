import asyncio
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types

from .agent import root_agent


async def _send(prompt: str, runner: Runner, session_id: str) -> None:
    async for event in runner.run_async(
        user_id="cli",
        session_id=session_id,
        new_message=types.Content(
            role="user",
            parts=[types.Part(text=prompt)],
        ),
    ):
        if event.is_final_response() and event.content:
            for part in event.content.parts:
                if part.text:
                    print(part.text)


async def _main() -> None:
    session_service = InMemorySessionService()
    session = await session_service.create_session(
        app_name="vm-agent",
        user_id="cli",
    )
    runner = Runner(
        agent=root_agent,
        app_name="vm-agent",
        session_service=session_service,
    )

    if len(sys.argv) > 1:
        await _send(" ".join(sys.argv[1:]), runner, session.id)
    else:
        print("vm-agent interactive mode (Ctrl-C to exit)")
        while True:
            try:
                prompt = input("> ").strip()
                if prompt:
                    await _send(prompt, runner, session.id)
            except (KeyboardInterrupt, EOFError):
                break


def main() -> None:
    asyncio.run(_main())


if __name__ == "__main__":
    main()
