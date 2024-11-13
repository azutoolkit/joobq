module JoobQ
  class JobSchemaRegistry
    property schemas : Hash(String, String) = {} of String => String

    def register(job_class : Class)
      @schemas[job_class.name] = job_class.json_schema.to_json
    end

    def json
      JSON.build do |json|
        json.object do
          @schemas.each do |job_class, schema|
            json.field(job_class) do
              json.raw(schema)
            end
          end
        end
      end
    end
  end
end
