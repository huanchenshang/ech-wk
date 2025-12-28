const WS_READY_STATE_OPEN = 1;
const WS_READY_STATE_CLOSING = 2;
const CF_FALLBACK_IPS = [
    '优选ip:端口'
];


// 复用 TextEncoder，避免重复创建
const encoder = new TextEncoder();


import { connect } from 'cloudflare:sockets';


export default {
    async fetch(request, env, ctx) {
        try {
            const token = '';
            const upgradeHeader = request.headers.get('Upgrade');

            if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
                return new URL(request.url).pathname === '/'
                    ? new Response('WebSocket Proxy Server', { status: 200 })
                    : new Response('Expected WebSocket', { status: 426 });
            }


            if (token && request.headers.get('Sec-WebSocket-Protocol') !== token) {
                return new Response('Unauthorized', { status: 401 });
            }


            const [client, server] = Object.values(new WebSocketPair());
            server.accept();

            handleSession(server).catch(() => safeCloseWebSocket(server));


            const responseInit = {
                status: 101,
                webSocket: client
            };

            if (token) {
                responseInit.headers = { 'Sec-WebSocket-Protocol': token };
            }


            return new Response(null, responseInit);

        } catch (err) {
            return new Response(err.toString(), { status: 500 });
        }
    },
};


async function handleSession(webSocket) {
    let remoteSocket, remoteWriter, remoteReader;
    let isClosed = false;


    const cleanup = () => {
        if (isClosed) return;
        isClosed = true;

        try { remoteWriter?.releaseLock(); } catch {}
        try { remoteReader?.releaseLock(); } catch {}
        try { remoteSocket?.close(); } catch {}

        remoteWriter = remoteReader = remoteSocket = null;
        safeCloseWebSocket(webSocket);
    };


    const pumpRemoteToWebSocket = async () => {
        try {
            while (!isClosed && remoteReader) {
                const { done, value } = await remoteReader.read();

                if (done) break;
                if (webSocket.readyState !== WS_READY_STATE_OPEN) break;
                if (value?.byteLength > 0) webSocket.send(value);
            }
        } catch {}

        if (!isClosed) {
            try { webSocket.send('CLOSE'); } catch {}
            cleanup();
        }
    };


    const parseAddress = (addr) => {
        if (addr[0] === '[') {
            const end = addr.indexOf(']');
            return {
                host: addr.substring(1, end),
                port: parseInt(addr.substring(end + 2), 10)
            };
        }
        const sep = addr.lastIndexOf(':');
        return {
            host: addr.substring(0, sep),
            port: parseInt(addr.substring(sep + 1), 10)
        };
    };


    const isCFError = (err) => {
        const msg = err?.message?.toLowerCase() || '';
        // 确保能捕获到 Cloudflare 的所有连接拒绝错误，包括 "consider using fetch" 的情况
        return msg.includes('proxy request') || 
               msg.includes('cannot connect') || 
               msg.includes('cloudflare') ||
               msg.includes('fetch instead'); // 添加此项以明确包含日志中的错误
    };


    const connectToRemote = async (targetAddr, firstFrameData) => {
        const { host, port } = parseAddress(targetAddr);
        // attempts 数组的第一个元素为 null，意味着第一次尝试使用原始的目标 host
        const attempts = [null, ...CF_FALLBACK_IPS]; 


        for (let i = 0; i < attempts.length; i++) {
            try {
                // 如果 attempts[i] 不为 null (即尝试备用 IP)，则重新解析 host 和 port
                let currentHost = host;
                let currentPort = port;
                
                if (attempts[i]) {
                    const fallback = parseAddress(attempts[i]);
                    currentHost = fallback.host;
                    currentPort = fallback.port;
                }

                remoteSocket = connect({
                    hostname: currentHost,
                    port: currentPort
                });


                if (remoteSocket.opened) await remoteSocket.opened;


                remoteWriter = remoteSocket.writable.getWriter();
                remoteReader = remoteSocket.readable.getReader();


                // 发送首帧数据
                if (firstFrameData) {
                    // **注意：这里假设 firstFrameData 可能是代理握手数据**
                    await remoteWriter.write(encoder.encode(firstFrameData));
                }


                webSocket.send('CONNECTED');
                pumpRemoteToWebSocket();
                return;


            } catch (err) {
                // 清理失败的连接
                try { remoteWriter?.releaseLock(); } catch {}
                try { remoteReader?.releaseLock(); } catch {}
                try { remoteSocket?.close(); } catch {}
                remoteWriter = remoteReader = remoteSocket = null;


                // 如果不是 CF 错误或已是最后尝试，抛出错误
                if (!isCFError(err) || i === attempts.length - 1) {
                    throw err;
                }
            }
        }
    };


    webSocket.addEventListener('message', async (event) => {
        if (isClosed) return;


        try {
            const data = event.data;


            if (typeof data === 'string') {
                if (data.startsWith('CONNECT:')) {
                    const sep = data.indexOf('|', 8);
                    await connectToRemote(
                        data.substring(8, sep),
                        data.substring(sep + 1)
                    );
                }
                else if (data.startsWith('DATA:')) {
                    if (remoteWriter) {
                        await remoteWriter.write(encoder.encode(data.substring(5)));
                    }
                }
                else if (data === 'CLOSE') {
                    cleanup();
                }
            }
            else if (data instanceof ArrayBuffer && remoteWriter) {
                await remoteWriter.write(new Uint8Array(data));
            }
        } catch (err) {
            try { webSocket.send('ERROR:' + err.message); } catch {}
            cleanup();
        }
    });


    webSocket.addEventListener('close', cleanup);
    webSocket.addEventListener('error', cleanup);
}


function safeCloseWebSocket(ws) {
    try {
        if (ws.readyState === WS_READY_STATE_OPEN ||
            ws.readyState === WS_READY_STATE_CLOSING) {
            ws.close(1000, 'Server closed');
        }
    } catch {}
}
