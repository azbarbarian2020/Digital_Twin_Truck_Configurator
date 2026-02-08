import { NextResponse } from "next/server";

export async function POST(request: Request): Promise<Response> {
  // Proxy to Python backend which has working key-pair auth for PUT commands
  const backendUrl = process.env.BACKEND_URL || 'http://127.0.0.1:8000';
  
  try {
    const formData = await request.formData();
    
    // Forward the request to the backend
    const backendResponse = await fetch(`${backendUrl}/api/engineering-docs/upload`, {
      method: 'POST',
      body: formData,
    });
    
    if (!backendResponse.ok) {
      const errorText = await backendResponse.text();
      console.error("Backend upload error:", errorText);
      return new Response(
        `data: ${JSON.stringify({ type: 'result', success: false, error: 'Backend upload failed' })}\n\n`,
        {
          headers: {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
          },
        }
      );
    }
    
    // Stream the response from backend
    return new Response(backendResponse.body, {
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      },
    });
    
  } catch (error) {
    console.error("Upload proxy error:", error);
    return new Response(
      `data: ${JSON.stringify({ type: 'result', success: false, error: (error as Error).message })}\n\n`,
      {
        headers: {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache',
        },
      }
    );
  }
}
