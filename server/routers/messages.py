from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from database import get_db
from models import Message, message_tag
from schemas import MessageResponse

router = APIRouter(prefix="/api/messages", tags=["messages"])


@router.get("", response_model=list[MessageResponse])
async def list_messages(
    conversation_id: str = Query(..., alias="conversationId"),
    tag_id: str | None = Query(None, alias="tagId"),
    db: AsyncSession = Depends(get_db),
):
    stmt = (
        select(Message)
        .options(selectinload(Message.tags))
        .where(Message.conversation_id == conversation_id)
        .order_by(Message.timestamp)
    )
    result = await db.execute(stmt)
    messages = result.scalars().all()

    if tag_id:
        messages = [m for m in messages if any(t.id == tag_id for t in m.tags)]

    return messages


@router.patch("/{message_id}/bookmark", response_model=MessageResponse)
async def toggle_bookmark(message_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Message)
        .options(selectinload(Message.tags))
        .where(Message.id == message_id)
    )
    message = result.scalar_one_or_none()
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    message.is_bookmarked = not message.is_bookmarked
    await db.flush()
    await db.refresh(message)
    return message
