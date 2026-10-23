package com.techbleat.bank.controller;

import com.techbleat.bank.dto.AmountRequest;
import com.techbleat.bank.dto.TransferRequest;
import com.techbleat.bank.service.TransactionService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/")
public class TransactionController {

    @Autowired
    private TransactionService transactionService;

    @GetMapping("/health")
    public Object health() {
        return java.util.Map.of("status", "ok");
    }

    @PostMapping(value = "/transactions/deposit", consumes = {"application/json", "application/x-www-form-urlencoded"})
    public Object deposit(
            Authentication authentication,
            @RequestHeader(value = "X-User-Id", required = false, defaultValue = "") String xUserId,
            @RequestBody AmountRequest request) {
        String userId = resolveUserId(authentication, xUserId);
        return transactionService.deposit(userId, request.getAmount());
    }

    @PostMapping(value = "/transactions/withdraw", consumes = {"application/json", "application/x-www-form-urlencoded"})
    public Object withdraw(
            Authentication authentication,
            @RequestHeader(value = "X-User-Id", required = false, defaultValue = "") String xUserId,
            @RequestBody AmountRequest request) {
        String userId = resolveUserId(authentication, xUserId);
        return transactionService.withdraw(userId, request.getAmount());
    }

    @PostMapping(value = "/transactions/transfer", consumes = {"application/json", "application/x-www-form-urlencoded"})
    public Object transfer(
            Authentication authentication,
            @RequestHeader(value = "X-User-Id", required = false, defaultValue = "") String xUserId,
            @RequestBody TransferRequest request) {
        String userId = resolveUserId(authentication, xUserId);
        return transactionService.transfer(userId, request.getToUserId(), request.getAmount(), request.getReference());
    }

    @GetMapping("/balance/{userId}")
    public Object balance(
            @PathVariable String userId,
            Authentication authentication) {
        assertOwnership(authentication, userId);
        return java.util.Map.of("userId", userId, "balance", transactionService.getBalance(userId));
    }

    @GetMapping("/transactions/{userId}")
    public Object transactions(
            @PathVariable String userId,
            Authentication authentication) {
        assertOwnership(authentication, userId);
        return transactionService.getTransactions(userId);
    }

    /**
     * Extracts preferred_username from a verified Keycloak JWT.
     * Falls back to the X-User-Id header only when running without JWT auth
     * (local Docker Compose dev mode — KEYCLOAK_JWK_SET_URI not set).
     */
    private String resolveUserId(Authentication authentication, String xUserId) {
        if (authentication instanceof JwtAuthenticationToken jwtToken) {
            Jwt jwt = (Jwt) jwtToken.getPrincipal();
            String username = jwt.getClaimAsString("preferred_username");
            if (username != null && !username.isBlank()) {
                return username;
            }
        }
        // Dev/no-auth fallback
        if (xUserId != null && !xUserId.isBlank()) {
            return xUserId;
        }
        throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Authentication required");
    }

    /**
     * Enforces that the caller may only access their own resources.
     * No-op when JWT auth is disabled (dev mode without Keycloak).
     */
    private void assertOwnership(Authentication authentication, String resourceUserId) {
        if (authentication instanceof JwtAuthenticationToken) {
            String callerId = resolveUserId(authentication, "");
            if (!callerId.equals(resourceUserId)) {
                throw new ResponseStatusException(HttpStatus.FORBIDDEN, "Access denied");
            }
        }
    }
}
