# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

module OpenTelemetry
  module Instrumentation
    module Mysql2
      module Patches
        # Module to prepend to Mysql2::Client for instrumentation
        module Client
          QUERY_NAMES = [
            'set names',
            'select',
            'insert',
            'update',
            'delete',
            'begin',
            'commit',
            'rollback',
            'savepoint',
            'release savepoint',
            'explain',
            'drop database',
            'drop table',
            'create database',
            'create table'
          ].freeze

          QUERY_NAME_RE = Regexp.new("^(#{QUERY_NAMES.join('|')})", Regexp::IGNORECASE)

          def query(sql, options = {})
            tracer.in_span(
              database_span_name(sql),
              attributes: client_attributes.merge(
                'db.statement' => sql
              ),
              kind: :client
            ) do
              super(sql, options)
            end
          end

          private

          def database_span_name(sql)
            # Setting span name to the SQL query without obfuscation would
            # result in PII + cardinality issues.
            # First attempt to infer the statement type then fallback to
            # current Otel approach {database.component_name}.{database_instance_name}
            # https://github.com/open-telemetry/opentelemetry-python/blob/39fa078312e6f41c403aa8cad1868264011f7546/ext/opentelemetry-ext-dbapi/tests/test_dbapi_integration.py#L53
            # This creates span names like mysql.default, mysql.replica, postgresql.staging etc.

            statement_type = extract_statement_type(sql)

            return statement_type unless statement_type.nil?

            # fallback
            database_name ? "mysql.#{database_name}" : 'mysql'
          end

          def database_name
            # https://github.com/brianmario/mysql2/blob/ca08712c6c8ea672df658bb25b931fea22555f27/lib/mysql2/client.rb#L78
            (query_options[:database] || query_options[:dbname] || query_options[:db])&.to_s
          end

          def client_attributes
            # The client specific attributes can be found via the query_options instance variable
            # exposed on the mysql2 Client
            # https://github.com/brianmario/mysql2/blob/ca08712c6c8ea672df658bb25b931fea22555f27/lib/mysql2/client.rb#L25-L26
            host = (query_options[:host] || query_options[:hostname]).to_s
            port = query_options[:port].to_s

            attributes = {
              'db.system' => 'mysql',
              'db.instance' => database_name,
              'db.url' => "mysql://#{host}:#{port}",
              'net.peer.name' => host,
              'net.peer.port' => port
            }
            attributes['peer.service'] = config[:peer_service] if config[:peer_service]
            attributes
          end

          def tracer
            Mysql2::Instrumentation.instance.tracer
          end

          def config
            Mysql2::Instrumentation.instance.config
          end

          def extract_statement_type(sql)
            QUERY_NAME_RE.match(sql) { |match| match[1].downcase } unless sql.nil?
          rescue StandardError => e
            OpenTelemetry.logger.debug("Error extracting sql statement type: #{e.message}")
          end
        end
      end
    end
  end
end
