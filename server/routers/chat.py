import json

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload
from sse_starlette.sse import EventSourceResponse

from database import get_db
from models import Conversation, Message
from schemas import ChatRequest
from services.deepseek import stream_chat

router = APIRouter(prefix="/api", tags=["chat"])


async def sse_generator(body: ChatRequest, db: AsyncSession):
    # 1. Get or create conversation
    if body.conversation_id:
        result = await db.execute(
            select(Conversation).where(Conversation.id == body.conversation_id)
        )
        conversation = result.scalar_one_or_none()
        if not conversation:
            yield {"event": "error", "data": json.dumps({"error": "Conversation not found"})}
            return
    else:
        title = body.content[:30] + ("..." if len(body.content) > 30 else "")
        conversation = Conversation(title=title)
        db.add(conversation)
        await db.flush()

    # Send start event with conversation id
    yield {
        "event": "message",
        "data": json.dumps({"type": "start", "conversationId": conversation.id}),
    }

    # 2. Save user message
    user_msg = Message(
        content=body.content,
        is_from_me=True,
        conversation_id=conversation.id,
    )
    db.add(user_msg)
    await db.flush()

    # 3. Load recent history (last 20 messages)
    result = await db.execute(
        select(Message)
        .options(selectinload(Message.tags))
        .where(Message.conversation_id == conversation.id)
        .order_by(Message.timestamp.desc())
        .limit(20)
    )
    recent = list(result.scalars().all())
    recent.reverse()

    history = [
        {"content": m.content, "is_from_me": m.is_from_me}
        for m in recent
    ]

    # 4. Stream from DeepSeek
    full_reply = ""
    try:
        async for token in stream_chat(history, body.content):
            full_reply += token
            yield {
                "event": "message",
                "data": json.dumps({"type": "token", "data": token}),
            }
    except Exception as e:
        yield {
            "event": "message",
            "data": json.dumps({"type": "error", "data": str(e)}),
        }
        return

    # 5. Save AI reply
    ai_msg = Message(
        content=full_reply,
        is_from_me=False,
        conversation_id=conversation.id,
    )
    db.add(ai_msg)
    await db.flush()

    # 6. Send done
    yield {
        "event": "message",
        "data": json.dumps({"type": "done"}),
    }


@router.post("/chat")
async def chat(body: ChatRequest, db: AsyncSession = Depends(get_db)):
    return EventSourceResponse(sse_generator(body, db))
