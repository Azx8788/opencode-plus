package com.azx8788.opencode.mini.shizuku;

interface IShizukuCommandService {
    void destroy() = 16777114; // Destroy method defined by Shizuku server

    String execute(String operationId, String expectedInstance, int expectedUid, String command, int timeoutMs, int outputLimitBytes) = 1;
    boolean cancel(String operationId) = 2;
    String status() = 3;
    String result(String operationId) = 4;
}
