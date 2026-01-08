#!/bin/bash

# Helper script to manage the vibe-check monitor process

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$SCRIPT_DIR/.monitor.pid"
MONITOR_SCRIPT="$HOME/Scripts/monitor_vibe_check.sh"
VENV_PYTHON="$SCRIPT_DIR/venv/bin/python3"

case "$1" in
    start)
        echo "Starting monitor..."
        bash "$MONITOR_SCRIPT"
        ;;

    stop)
        if [ -f "$PID_FILE" ]; then
            PID=$(cat "$PID_FILE")
            if ps -p "$PID" > /dev/null 2>&1; then
                echo "Stopping monitor (PID: $PID)..."
                kill "$PID"
                rm "$PID_FILE"
                echo "Monitor stopped"
            else
                echo "Monitor not running (stale PID file)"
                rm "$PID_FILE"
            fi
        else
            echo "Monitor not running (no PID file)"
        fi
        ;;

    restart)
        $0 stop
        sleep 2
        $0 start
        ;;

    status)
        if [ -f "$PID_FILE" ]; then
            PID=$(cat "$PID_FILE")
            if ps -p "$PID" > /dev/null 2>&1; then
                echo "Monitor is running (PID: $PID)"
                ps -p "$PID" -o pid,etime,command
            else
                echo "Monitor not running (stale PID file)"
            fi
        else
            echo "Monitor not running"
        fi
        ;;

    install-cron)
        echo "Installing cron job to check every 15 minutes..."

        # Check if cron job already exists
        if crontab -l 2>/dev/null | grep -q "monitor_vibe_check.sh"; then
            echo "Cron job already exists:"
            crontab -l | grep "monitor_vibe_check.sh"
        else
            # Add to crontab
            (crontab -l 2>/dev/null; echo "*/15 * * * * $MONITOR_SCRIPT") | crontab -
            echo "Cron job installed:"
            crontab -l | grep "monitor_vibe_check.sh"
        fi
        ;;

    uninstall-cron)
        echo "Removing cron job..."
        crontab -l 2>/dev/null | grep -v "monitor_vibe_check.sh" | crontab -
        echo "Cron job removed"
        ;;

    logs)
        LOG_FILE="$HOME/logs/vibe_check_monitor.log"
        MONITOR_LOG="$SCRIPT_DIR/monitor.log"

        echo "=== Monitor check log (last 20 lines) ==="
        if [ -f "$LOG_FILE" ]; then
            tail -20 "$LOG_FILE"
        else
            echo "No log file found at $LOG_FILE"
        fi

        echo ""
        echo "=== Monitor output (last 30 lines) ==="
        if [ -f "$MONITOR_LOG" ]; then
            tail -30 "$MONITOR_LOG"
        else
            echo "No output log found at $MONITOR_LOG"
        fi
        ;;

    *)
        echo "Usage: $0 {start|stop|restart|status|install-cron|uninstall-cron|logs}"
        echo ""
        echo "Commands:"
        echo "  start         - Start the monitor"
        echo "  stop          - Stop the monitor"
        echo "  restart       - Restart the monitor"
        echo "  status        - Check if monitor is running"
        echo "  install-cron  - Install cron job to check every 15 minutes"
        echo "  uninstall-cron- Remove the cron job"
        echo "  logs          - View recent logs"
        exit 1
        ;;
esac
