import { NextRequest } from "next/server";

export async function GET(request: NextRequest): Promise<Response> {
  const docId = request.nextUrl.searchParams.get("docId");
  
  if (!docId) {
    return new Response(JSON.stringify({ error: "No docId provided" }), { 
      status: 400,
      headers: { 'Content-Type': 'application/json' }
    });
  }
  
  try {
    const backendUrl = `http://127.0.0.1:8000/api/engineering-docs/download?docId=${encodeURIComponent(docId)}`;
    const response = await fetch(backendUrl, { redirect: 'manual' });
    
    if (response.status === 302) {
      const redirectUrl = response.headers.get('location');
      if (redirectUrl) {
        return Response.redirect(redirectUrl, 302);
      }
    }
    
    if (!response.ok) {
      const error = await response.text();
      return new Response(error, { 
        status: response.status,
        headers: { 'Content-Type': 'application/json' }
      });
    }
    
    const pdfBuffer = await response.arrayBuffer();
    const contentDisposition = response.headers.get('content-disposition') || `inline; filename="document.pdf"`;
    
    return new Response(pdfBuffer, {
      headers: {
        'Content-Type': 'application/pdf',
        'Content-Disposition': contentDisposition,
        'Content-Length': pdfBuffer.byteLength.toString(),
      },
    });
  } catch (error) {
    console.error("Download doc error:", error);
    return new Response(JSON.stringify({ error: "Failed to retrieve document" }), { 
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    });
  }
}
