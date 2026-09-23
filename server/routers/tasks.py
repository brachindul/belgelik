from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException, Request
from fastapi.responses import FileResponse, Response
from core import *  # noqa: F401,F403

router = APIRouter()


@router.get("/tasks", dependencies=[Depends(check_auth)])
def list_tasks(date: str):
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM tasks WHERE date = ? ORDER BY id",
            (date,),
        ).fetchall()
    return {"items": [_task_row_to_dict(r) for r in rows]}


@router.post("/tasks", dependencies=[Depends(check_auth)])
def create_task(body: TaskIn):
    now = int(time.time())
    with db() as conn:
        cur = conn.execute(
            """
            INSERT INTO tasks (date, subject, target_minutes, done, updated_at)
            VALUES (?, ?, ?, 0, ?)
            """,
            (body.date, body.subject, body.target_minutes, now),
        )
        new_id = cur.lastrowid
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (new_id,)).fetchone()
    return _task_row_to_dict(row)


@router.put("/tasks/{task_id}", dependencies=[Depends(check_auth)])
def update_task(task_id: int, body: TaskUpdate):
    now = int(time.time())
    with db() as conn:
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Gorev bulunamadi")
        subject = body.subject if body.subject is not None else row["subject"]
        target = (
            body.target_minutes
            if body.target_minutes is not None
            else row["target_minutes"]
        )
        done = (
            (1 if body.done else 0) if body.done is not None else row["done"]
        )
        conn.execute(
            """
            UPDATE tasks
            SET subject = ?, target_minutes = ?, done = ?, updated_at = ?
            WHERE id = ?
            """,
            (subject, target, done, now, task_id),
        )
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    return _task_row_to_dict(row)


@router.delete("/tasks/{task_id}", dependencies=[Depends(check_auth)])
def delete_task(task_id: int):
    with db() as conn:
        conn.execute("DELETE FROM tasks WHERE id = ?", (task_id,))
    return {"ok": True}
