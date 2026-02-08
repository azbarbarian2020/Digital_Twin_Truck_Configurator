import { NextResponse } from "next/server";

export async function DELETE(
  request: Request,
  { params }: { params: Promise<{ configId: string }> }
) {
  const { configId } = await params;
  
  // Proxy to Python backend which has working database connection
  const backendUrl = process.env.BACKEND_URL || 'http://127.0.0.1:8000';
  
  try {
    const response = await fetch(`${backendUrl}/api/configs/${configId}`, {
      method: 'DELETE',
    });
    
    if (!response.ok) {
      const errorText = await response.text();
      console.error("Backend delete error:", errorText);
      return NextResponse.json({ error: "Failed to delete config" }, { status: 500 });
    }
    
    return NextResponse.json({ success: true });
  } catch (error) {
    console.error("Delete proxy error:", error);
    return NextResponse.json({ error: (error as Error).message }, { status: 500 });
  }
}
