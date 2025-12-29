# Deploying to Hostgator

## Prerequisites

- SSH access enabled
- Python 3.7+ available
- MySQL database created (`wanderin_vibecheck`)

## Deployment Steps

### 1. Upload Files

Upload the entire `server/` directory to your Hostgator account. Suggested location:
```
~/vibecheck.wanderingstan.com/
```

### 2. Setup Python App in cPanel

1. **Login to cPanel**
2. **Find "Setup Python App"** (under Software section)
3. **Click "Create Application"**

Configure:
- **Python version**: 3.7 or higher (choose latest available)
- **Application root**: `/home/username/vibecheck.wanderingstan.com`
- **Application URL**: Choose a subdomain or path (e.g., `vibecheck.wanderingstan.com`)
- **Application startup file**: `passenger_wsgi.py`
- **Application Entry point**: `application`

4. **Click "Create"**

### 3. Install Dependencies

After creating the app, cPanel will show you a command to enter the virtual environment. It looks like:

```bash
source /home/username/virtualenv/vibecheck.wanderingstan.com/3.9/bin/activate
```

Run this, then install dependencies:

```bash
cd ~/vibecheck.wanderingstan.com
source /home/username/virtualenv/vibecheck.wanderingstan.com/3.9/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

### 4. Configure Application

Edit `config.json` with your database credentials:

```json
{
  "mysql": {
    "host": "localhost",
    "port": 3306,
    "user": "wanderin_vibecheck_admin",
    "password": "YOUR-DB-PASSWORD",
    "database": "wanderin_vibecheck"
  },
  "server": {
    "host": "0.0.0.0",
    "port": 5000
  }
}
```

**Note**: The `host` and `port` in config won't be used by Passenger, but keep them for compatibility.

### 5. Setup Database

Via phpMyAdmin:
1. Go to `wanderin_vibecheck` database
2. Run the SQL from `schema.sql`

### 6. Generate API Key

On your local machine:
```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Copy the output, then in phpMyAdmin:
```sql
INSERT INTO api_keys (user_name, api_key)
VALUES ('stan', 'paste-generated-key-here');
```

### 7. Restart Application

In cPanel → Setup Python App → Click "Restart" button next to your app

### 8. Test

```bash
# From your local machine
curl https://vibecheck.wanderingstan.com/health
```

Should return: `{"status":"ok"}`

Test with API key:
```bash
curl -H "X-API-Key: your-api-key" https://vibecheck.wanderingstan.com/events?limit=5
```

## Alternative: Manual Setup with Gunicorn

If cPanel Python App isn't available, you can try running manually via SSH:

### Install Gunicorn

```bash
cd ~/vibecheck.wanderingstan.com
source venv/bin/activate
pip install gunicorn
```

### Run Gunicorn

```bash
gunicorn -w 4 -b 0.0.0.0:5000 app:app --daemon
```

**Warning**: Shared hosting often kills long-running processes. You may need to:
- Use a screen/tmux session
- Create a cron job to restart it periodically
- Use Passenger (via cPanel Python App) instead

### Create Restart Script

```bash
#!/bin/bash
# ~/restart_vibecheck.sh

cd ~/vibecheck.wanderingstan.com
source venv/bin/activate

# Kill existing process
pkill -f "gunicorn.*app:app"

# Start new process
gunicorn -w 4 -b 0.0.0.0:5000 app:app --daemon --access-logfile logs/access.log --error-logfile logs/error.log
```

Make executable:
```bash
chmod +x ~/restart_vibecheck.sh
```

Add to crontab (runs every 10 minutes if process died):
```bash
crontab -e
```

Add line:
```
*/10 * * * * ~/restart_vibecheck.sh
```

## Troubleshooting

### Can't connect to server
- Check if Python app is running in cPanel
- Check application logs (shown in cPanel Python App section)
- Verify firewall/port settings

### Database connection errors
- Verify MySQL credentials in `config.json`
- Check if `localhost` is correct (some hosts use `127.0.0.1` or a specific hostname)
- Test connection manually

### Import errors
- Ensure all dependencies are installed in the virtual environment
- Check Python version matches your app requirements

### Performance issues
- Increase number of workers (if using Gunicorn)
- Check Hostgator resource limits
- Consider upgrading to VPS if shared hosting is too limited
