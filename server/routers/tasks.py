from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from database import get_db
from models import ScheduledTask
from schemas import TaskCreate, TaskResponse

router = APIRouter(prefix="/api/tasks", tags=["tasks"])


@router.get("", response_model=list[TaskResponse])
async def list_tasks(db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(ScheduledTask).order_by(ScheduledTask.title)
    )
    return result.scalars().all()


@router.post("", response_model=TaskResponse, status_code=201)
async def create_task(body: TaskCreate, db: AsyncSession = Depends(get_db)):
    task = ScheduledTask(
        type=body.type,
        title=body.title,
        cron_expression=body.cron_expression,
    )
    db.add(task)
    await db.flush()
    await db.refresh(task)
    return task


@router.patch("/{task_id}/toggle", response_model=TaskResponse)
async def toggle_task(task_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(ScheduledTask).where(ScheduledTask.id == task_id)
    )
    task = result.scalar_one_or_none()
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    task.is_enabled = not task.is_enabled
    await db.flush()
    await db.refresh(task)
    return task
