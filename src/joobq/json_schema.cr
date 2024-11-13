require "json"
require "uuid"

module JSON
  module Schema
    def json_schema(openapi : Bool? = nil)
      {% begin %}
        {% properties = {} of Nil => Nil %}
        {% for ivar in @type.instance_vars %}
          {% ann = ivar.annotation(::JSON::Field) %}
          {% unless ann && (ann[:ignore] || ann[:ignore_deserialize]) %}
            {% properties[((ann && ann[:key]) || ivar).id] = {ivar.type.resolve, (ann && ann[:converter]), (ann && ann.named_args)} %}
          {% end %}
        {% end %}

        {% if properties.empty? %}
          { type: "object" }
        {% else %}
          {type: "object",  properties: {
            {% for key, details in properties %}
              {% ivar = details[0] %}
              {% converter = details[1] %}
              {% args = details[2] %}
              {% if ivar < Enum && converter %}
                # we don't specify the type of the enum as we don't know what will be output
                # all we know is that it can be parsed as JSON
                {{key}}: { enum: [
                  {% for const in ivar.constants %}
                    JSON.parse({{converter.resolve}}.to_json({{ivar.name}}::{{const}}).as(String)),
                  {% end %}
                ]},
              {% else %}
                {{key}}: openapi ? ::JSON::Schema.introspect({{ivar.name}}, {{args}}, true) : ::JSON::Schema.introspect({{ivar.name}}, {{args}}),
              {% end %}
            {% end %}
          },
            {% required = [] of String %}
            {% for key, details in properties %}
              {% ivar = details[0] %}
              {% unless ivar.nilable? %}
                {% required << key.stringify %}
              {% end %}
            {% end %}
            {% unless required.empty? %}
              required: [
              {% for key in required %}
                {{key}},
              {% end %}
              ]
            {% end %}
          }
        {% end %}
      {% end %}
    end

    macro introspect(klass, args = nil, openapi = nil)
      {% format_hint = (args && args[:format]) %}
      {% type_override = (args && args[:type]) %}
      {% pattern = (args && args[:pattern]) %}
      {% description = (args && args[:description]) %}

      {% arg_name = klass.stringify %}
      {% if !arg_name.starts_with?("Union") && arg_name.includes?("|") %}
        ::JSON::Schema.introspect(Union({{klass}}), {{args}}, {{openapi}})
      {% else %}
        {% klass = klass.resolve %}
        {% klass_name = klass.name(generic_args: false) %}
        {% nillable = klass.nilable? %}

        {% if klass <= Array || klass <= Set %}
          {% if klass.type_vars.size == 1 %}
            %has_items = ::JSON::Schema.introspect({{klass.type_vars[0]}}, nil, {{openapi}})
            {type: "array"{% if description %}, description: {{description}}{% end %}, items: %has_items}
          {% else %}
            # handle inheritance (no access to type_var / unknown value)
            %klass = {{klass.ancestors[0]}}
            %klass.responds_to?(:json_schema) ? %klass.json_schema({{openapi}}) : { type: "array"{% if description %}, description: {{description}}{% end %} }
          {% end %}
        {% elsif klass.union? && !openapi.nil? && nillable && klass.union_types.size == 2 %}
          {% for type in klass.union_types %}
            {% if type.stringify != "Nil" %}
              JSON.parse(::JSON::Schema.introspect({{type}}, {{args}}, {{openapi}}).to_json[0..-2] + %(,"nullable":true}))
            {% end %}
          {% end %}
        {% elsif klass.union? %}
          { anyOf: {
            {% for type in klass.union_types %}
              {% if openapi.nil? || type.stringify != "Nil" %}
                ::JSON::Schema.introspect({{type}}, nil, {{openapi}}),
              {% end %}
            {% end %}
          }{% if !openapi.nil? && nillable %}, nullable: true{% end %}{% if description %}, description: {{description}}{% end %} }
        {% elsif klass_name.starts_with? "Tuple(" %}
          %has_items = {
            {% for generic in klass.type_vars %}
              ::JSON::Schema.introspect({{generic}}, nil, {{openapi}}),
            {% end %}
          }
          {type: "array"{% if description %}, description: {{description}}{% end %}, items: %has_items}
        {% elsif klass_name.starts_with? "NamedTuple(" %}
          {% if klass.keys.empty? %}
            {type: "object"{% if description %}, description: {{description}}{% end %},  properties: {} of Symbol => Nil}
          {% else %}
            {type: "object"{% if description %}, description: {{description}}{% end %},  properties: {
              {% for key in klass.keys %}
                {{key.id}}: ::JSON::Schema.introspect({{klass[key].resolve.name}}, nil, {{openapi}}),
              {% end %}
            },
              {% required = [] of String %}
              {% for key in klass.keys %}
                {% if !klass[key].resolve.nilable? %}
                  {% required << key.id.stringify %}
                {% end %}
              {% end %}
              {% if !required.empty? %}
                required: [
                {% for key in required %}
                  {{key}},
                {% end %}
                ]
              {% end %}
            }
          {% end %}
        {% elsif klass < Enum %}
          {type: "string",  enum: {{klass.constants.map(&.stringify.underscore)}}{% if description %}, description: {{description}}{% end %} }
        {% elsif klass <= String || klass <= Symbol %}
          {% min_length = (args && args[:min_length]) %}
          {% max_length = (args && args[:max_length]) %}
          { type: {{type_override || "string"}}{% if format_hint %}, format: {{format_hint}}{% end %}{% if pattern %}, pattern: {{pattern}}{% end %}{% if min_length %}, minLength: {{min_length}}{% end %}{% if max_length %}, maxLength: {{max_length}}{% end %}{% if description %}, description: {{description}}{% end %} }
        {% elsif klass <= Bool %}
          { type: {{type_override || "boolean"}}{% if format_hint %}, format: {{format_hint}}{% end %}{% if description %}, description: {{description}}{% end %} }
        {% elsif klass <= Int || klass <= Float %}
          {% multiple_of = (args && args[:multiple_of]) %}
          {% minimum = (args && args[:minimum]) %}
          {% exclusive_minimum = (args && args[:exclusive_minimum]) %}
          {% maximum = (args && args[:maximum]) %}
          {% exclusive_maximum = (args && args[:exclusive_maximum]) %}
          {% if klass <= Int %}
            { type: {{type_override || "integer"}}, format: {{format_hint || klass.stringify}}{% if multiple_of %}, multipleOf: {{multiple_of}}{% end %}{% if minimum %}, minimum: {{minimum}}{% end %}{% if exclusive_minimum %}, exclusiveMinimum: {{exclusive_minimum}}{% end %}{% if maximum %}, maximum: {{maximum}}{% end %}{% if exclusive_maximum %}, exclusiveMaximum: {{exclusive_maximum}}{% end %}{% if description %}, description: {{description}}{% end %} }
          {% elsif klass <= Float %}
            { type: {{type_override || "number"}}, format: {{format_hint || klass.stringify}}{% if multiple_of %}, multipleOf: {{multiple_of}}{% end %}{% if minimum %}, minimum: {{minimum}}{% end %}{% if exclusive_minimum %}, exclusiveMinimum: {{exclusive_minimum}}{% end %}{% if maximum %}, maximum: {{maximum}}{% end %}{% if exclusive_maximum %}, exclusiveMaximum: {{exclusive_maximum}}{% end %}{% if description %}, description: {{description}}{% end %} }
          {% end %}
        {% elsif klass <= Nil %}
          { type: {{type_override || "null"}}{% if description %}, description: {{description}}{% end %} }
        {% elsif klass <= Time %}
          { type: {{type_override || "string"}}, format: {{format_hint || "date-time"}}{% if pattern %}, pattern: {{pattern}}{% end %}{% if description %}, description: {{description}}{% end %} }
        {% elsif klass <= UUID %}
          { type: {{type_override || "string"}}, format: {{format_hint || "uuid"}}{% if pattern %}, pattern: {{pattern}}{% end %}{% if description %}, description: {{description}}{% end %} }
        {% elsif klass <= Hash %}
          {% if klass.type_vars.size == 2 %}
            { type: "object", additionalProperties: ::JSON::Schema.introspect({{klass.type_vars[1]}}, nil, {{openapi}}) }
          {% else %}
            # As inheritance might include the type_vars it's hard to work them out
            %klass = {{klass.ancestors[0]}}
            %klass.responds_to?(:json_schema) ? %klass.json_schema({{openapi}}) : { type: "object"{% if description %}, description: {{description}}{% end %} }
          {% end %}
        {% elsif klass.ancestors.includes? JSON::Serializable %}
          {{klass}}.json_schema({{openapi}})
        {% else %}
          %klass = {{klass}}
          if %klass.responds_to?(:json_schema)
            %klass.json_schema({{openapi}})
          else
            # anything will validate (JSON::Any)
            { type: "object"{% if description %}, description: {{description}}{% end %} }
          end
        {% end %}
      {% end %}
    end
  end

  module Serializable
    macro included
      extend JSON::Schema
    end
  end
end
