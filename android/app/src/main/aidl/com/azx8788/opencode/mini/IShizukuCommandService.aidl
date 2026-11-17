package com.azx8788.opencode.mini;

interface IShizukuCommandService {
    void destroy() = 16777114;
    String execute(String operationId, String command, int timeoutMs, int outputLimitBytes);
    boolean cancel(String operationId);
    String status();
}
