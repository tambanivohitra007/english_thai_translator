const WebSocket = require('ws');
const express = require('express');
const http = require('http');

// Configuration
const PORT = process.env.PORT || 9090;
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
const OPENAI_REALTIME_URL = 'wss://api.openai.com/v1/realtime?model=gpt-realtime-mini-2025-10-06';

// System prompts for each direction
const PROMPTS = {
  'en-th': `You are a real-time interpreter for daily conversations in Thailand.
Translate spoken English into short, polite, natural Thai suitable for face-to-face speech.
Simplify complex sentences.
Preserve intent rather than literal wording.
Use casual but respectful Thai.
Add polite particles naturally.
Avoid formal, written, or academic Thai.`,

  'th-en': `You are a real-time interpreter for daily conversations in Thailand.
Translate spoken Thai into clear, simple, natural English suitable for face-to-face conversation.
Preserve intent rather than literal wording.
Keep sentences short and conversational.
Avoid formal or academic English.
Do not explain the translation.`
};

// Create Express app
const app = express();
const server = http.createServer(app);
// const wss = new WebSocket.Server({ server, path: '/realtime' });
const wss = new WebSocket.Server({ noServer: true });

server.on('upgrade', (req, socket, head) => {
  if (req.url === '/realtime') {
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit('connection', ws, req);
    });
  } else {
    socket.destroy();
  }
});


// Health check endpoint
app.get('/health', (req, res) => {
  res.status(200).send('OK');
});

app.get('/', (req, res) => {
  res.status(200).send('Realtime Translator Proxy v1.0');
});

// WebSocket connection handler
wss.on('connection', (clientWs, req) => {
  console.log('Client connected');
  
  let openaiWs = null;
  let currentDirection = 'en-th'; // Default direction
  let isConnected = false;

  // Connect to OpenAI Realtime API
  const connectToOpenAI = () => {
    try {
      openaiWs = new WebSocket(OPENAI_REALTIME_URL, {
        headers: {
          'Authorization': `Bearer ${OPENAI_API_KEY}`,
          'OpenAI-Beta': 'realtime=v1'
        }
      });

      openaiWs.on('open', () => {
        console.log('Connected to OpenAI Realtime API');
        isConnected = true;
        
        // Send initial session configuration
        sendSessionUpdate(currentDirection);
      });

      openaiWs.on('message', (data) => {
        // Forward all messages from OpenAI to client
        if (clientWs.readyState === WebSocket.OPEN) {
          clientWs.send(data);
        }
      });

      openaiWs.on('error', (error) => {
        console.error('OpenAI WebSocket error:', error);
        if (clientWs.readyState === WebSocket.OPEN) {
          clientWs.send(JSON.stringify({
            type: 'error',
            error: { message: 'OpenAI connection error' }
          }));
        }
      });

      openaiWs.on('close', () => {
        console.log('OpenAI connection closed');
        isConnected = false;
        if (clientWs.readyState === WebSocket.OPEN) {
          clientWs.close();
        }
      });

    } catch (error) {
      console.error('Error connecting to OpenAI:', error);
    }
  };

  // Send session update with appropriate prompt
  const sendSessionUpdate = (direction, voice = 'alloy') => {
    if (!openaiWs || openaiWs.readyState !== WebSocket.OPEN) return;

    const instructions = PROMPTS[direction] || PROMPTS['en-th'];
    
    const sessionConfig = {
      type: 'session.update',
      session: {
        modalities: ['text', 'audio'],
        instructions: instructions,
        voice: voice,
        input_audio_format: 'pcm16',
        output_audio_format: 'pcm16',
        input_audio_transcription: {
          model: 'whisper-1'
        },
        turn_detection: {
          type: 'server_vad',
          threshold: 0.5,
          prefix_padding_ms: 300,
          silence_duration_ms: 500
        },
        temperature: 0.3,
        max_response_output_tokens: 100
      }
    };

    openaiWs.send(JSON.stringify(sessionConfig));
    console.log(`Session updated for direction: ${direction}`);
  };

  // Handle messages from client
  clientWs.on('message', (message) => {
    try {
      const data = JSON.parse(message);

      // Handle direction change
      if (data.type === 'set_direction') {
        currentDirection = data.direction || 'en-th';
        const voice = data.voice || 'alloy';
        console.log(`Direction changed to: ${currentDirection}, voice: ${voice}`);
        
        if (isConnected) {
          sendSessionUpdate(currentDirection, voice);
        }
        return;
      }

      // Forward all other messages to OpenAI
      if (openaiWs && openaiWs.readyState === WebSocket.OPEN) {
        openaiWs.send(message);
      } else {
        console.warn('OpenAI not connected, message dropped');
      }

    } catch (error) {
      // Not JSON, forward as-is (shouldn't happen but be safe)
      if (openaiWs && openaiWs.readyState === WebSocket.OPEN) {
        openaiWs.send(message);
      }
    }
  });

  clientWs.on('close', () => {
    console.log('Client disconnected');
    if (openaiWs) {
      openaiWs.close();
    }
  });

  clientWs.on('error', (error) => {
    console.error('Client WebSocket error:', error);
  });

  // Start connection to OpenAI
  connectToOpenAI();
});

// Start server
server.listen(PORT, () => {
  console.log(`Realtime Translator Proxy running on port ${PORT}`);
  console.log(`WebSocket endpoint: ws://localhost:${PORT}/realtime`);

  
  if (!OPENAI_API_KEY) {
    console.error('WARNING: OPENAI_API_KEY environment variable not set!');
  }
});

