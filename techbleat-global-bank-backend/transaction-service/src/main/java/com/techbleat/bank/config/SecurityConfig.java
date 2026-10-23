package com.techbleat.bank.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;

/**
 * Spring Security configuration for the transaction-service.
 *
 * <p>When {@code KEYCLOAK_JWK_SET_URI} is set (non-empty), all endpoints except
 * {@code /actuator/**} require a valid Keycloak JWT.  When the env var is empty
 * (the default for local Docker Compose without OTel), the service behaves as if
 * security is disabled so the app continues to work without Keycloak integration.
 *
 * <p>For production (Kubernetes/EKS) set:
 * <pre>
 *   KEYCLOAK_JWK_SET_URI=http://keycloak:8080/realms/banking/protocol/openid-connect/certs
 * </pre>
 */
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Value("${spring.security.oauth2.resourceserver.jwt.jwk-set-uri:}")
    private String jwkSetUri;

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .sessionManagement(sm -> sm.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .csrf(csrf -> csrf.disable());

        if (jwkSetUri != null && !jwkSetUri.isBlank()) {
            // JWT validation enabled — require authentication on all endpoints
            // except health checks and Actuator endpoints.
            http
                .authorizeHttpRequests(auth -> auth
                    .requestMatchers("/actuator/**", "/health").permitAll()
                    .anyRequest().authenticated()
                )
                .oauth2ResourceServer(oauth2 -> oauth2
                    .jwt(jwt -> {
                        // JWK URI is already set via spring.security.oauth2.resourceserver.jwt.jwk-set-uri
                    })
                );
        } else {
            // No JWK URI configured — permit all requests (dev / no-Keycloak mode).
            http.authorizeHttpRequests(auth -> auth.anyRequest().permitAll());
        }

        return http.build();
    }
}
