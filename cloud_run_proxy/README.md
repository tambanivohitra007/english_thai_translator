# Realtime Translator Proxy - Cloud Run Deployment

## Prerequisites

1. **Google Cloud SDK** - [Install here](https://cloud.google.com/sdk/docs/install)
   - Windows: Download and run the installer from the link above
   - After installation, restart PowerShell/Terminal
2. **Docker Desktop** (for local testing) - [Install here](https://www.docker.com/products/docker-desktop/)
3. **OpenAI API key** with Realtime API access

## Option 1: Install Google Cloud SDK (Required for Cloud Run)

### Windows Installation

1. Download installer: https://cloud.google.com/sdk/docs/install
2. Run `GoogleCloudSDKInstaller.exe`
3. Follow installation wizard
4. **Restart PowerShell** after installation
5. Verify: `gcloud --version`

### Quick Setup

```powershell
# Initialize gcloud
gcloud init

# Login
gcloud auth login

# Set project
gcloud config set project YOUR_PROJECT_ID
```

## Option 2: Test Locally First (No Cloud Deployment)

## Option 2: Test Locally First (No Cloud Deployment)

### Using Node.js Directly

```powershell
cd cloud_run_proxy

# Install dependencies
npm install

# Set environment variable (PowerShell)
$env:OPENAI_API_KEY="your-openai-api-key-here"

# Run server
npm start

# Server runs at ws://localhost:8080/realtime
```

### Using Docker (Alternative)

```powershell
cd cloud_run_proxy

# Build image
docker build -t realtime-proxy .

# Run container
docker run -p 8080:8080 -e OPENAI_API_KEY="your-key" realtime-proxy

# Server runs at ws://localhost:8080/realtime
```

### Test Connection

Open a new terminal and test:

```powershell
# Check health endpoint
curl http://localhost:8080/health

# Or open in browser
start http://localhost:8080
```

Update Flutter app to use local server:

```dart
// In lib/main.dart, line 17
const String _cloudRunProxyUrl = 'ws://localhost:8080/realtime';
```

**Note**: For Android emulator, use `ws://10.0.2.2:8080/realtime` instead.

## Option 3: Deploy to Cloud Run (Production)

### 1. Install Google Cloud SDK (if not done)

```bash
cd cloud_run_proxy

# Install dependencies
npm install

# Set environment variable
export OPENAI_API_KEY="your-openai-api-key-here"

# Run locally
npm start

# Test connection (separate terminal)
# Server should be available at ws://localhost:8080/realtime
```

## Deploy to Cloud Run

### 1. Set up Google Cloud

```bash
# Set your project ID
export PROJECT_ID="your-gcp-project-id"
export REGION="us-central1"
export SERVICE_NAME="realtime-translator-proxy"

# Login and set project
gcloud auth login
gcloud config set project $PROJECT_ID

# Enable required APIs
gcloud services enable cloudbuild.googleapis.com
gcloud services enable run.googleapis.com
gcloud services enable artifactregistry.googleapis.com
```

### 2. Build and Deploy

```bash
cd cloud_run_proxy

# Build and deploy in one command
gcloud run deploy $SERVICE_NAME \
  --source . \
  --platform managed \
  --region $REGION \
  --allow-unauthenticated \
  --set-env-vars OPENAI_API_KEY="your-openai-api-key-here" \
  --min-instances 1 \
  --max-instances 10 \
  --memory 512Mi \
  --cpu 1 \
  --timeout 3600 \
  --session-affinity
```

### 3. Get Service URL

```bash
gcloud run services describe $SERVICE_NAME --region $REGION --format 'value(status.url)'
```

The output will be something like:
```
https://realtime-translator-proxy-abc123-uc.a.run.app
```

### 4. Update Flutter App

Take the service URL and update the Flutter app:

```dart
// In lib/main.dart
const String _cloudRunProxyUrl = 'wss://realtime-translator-proxy-abc123-uc.a.run.app/realtime';
```

Replace `https://` with `wss://` and append `/realtime` path.

## Environment Variables

Set in Cloud Run:

- `OPENAI_API_KEY`: Your OpenAI API key (required)
- `PORT`: Auto-set by Cloud Run (default: 8080)

## Security Notes

- API key is stored as Cloud Run environment variable (encrypted at rest)
- Service allows unauthenticated access (protected by obscurity)
- For production: Add authentication header validation
- For production: Use Secret Manager instead of env vars

## Monitoring

```bash
# View logs
gcloud run services logs read $SERVICE_NAME --region $REGION --limit 50

# View real-time logs
gcloud run services logs tail $SERVICE_NAME --region $REGION
```

## Cost Optimization

- Minimum instances: 1 (for instant connection, ~$10/month)
- For lower cost: Set `--min-instances 0` (cold start ~3-5 seconds)
- Timeout: 3600s (1 hour max conversation)
- Memory: 512Mi (sufficient for WebSocket proxy)

## Troubleshooting

### Connection Refused
- Check service is running: `gcloud run services list`
- Check logs for errors
- Verify OPENAI_API_KEY is set

### High Latency
- Check Cloud Run region matches OpenAI region preference
- Consider increasing CPU/memory
- Check network between client and Cloud Run

### WebSocket Disconnects
- Cloud Run has 1 hour timeout (cannot be extended)
- Implement reconnection logic in Flutter app
- Use session affinity for better stability
