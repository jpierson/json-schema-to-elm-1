defmodule JS2E.Parser do
  @moduledoc ~S"""
  Parses JSON schema files into an intermediate representation to be used for
  e.g. printing elm decoders.
  """

  require Logger
  alias JS2E.Parsers.{ArrayParser, ObjectParser, EnumParser, PrimitiveParser,
                      DefinitionsParser, AllOfParser, AnyOfParser, OneOfParser,
                      UnionParser, TupleParser, TypeReferenceParser}
  alias JS2E.{TypePath, Types, Predicates}
  alias JS2E.Types.SchemaDefinition

  @type nodeParser :: (
    map, URI.t, URI.t, TypePath.t, String.t -> Types.typeDictionary
  )

  @supported_versions [
    "http://json-schema.org/draft-04/schema"
  ]

  @spec parse_schema_files([String.t], String.t) :: Types.schemaDictionary
  def parse_schema_files(json_schema_paths, module_name) do
    json_schema_paths
    |> Enum.reduce(%{}, fn (json_schema_path, schema_dict) ->

      json_schema_path
      |> parse_schema_file(module_name)
      |> Map.merge(schema_dict)
    end)
  end

  @spec parse_schema_file(String.t, String.t) :: Types.schemaDictionary
  def parse_schema_file(json_schema_path, module_name) do
    json_schema_path
    |> File.read!
    |> Poison.decode!
    |> parse_schema(module_name)
  end

  @spec parse_schema(map, String.t) :: Types.schemaDictionary
  def parse_schema(schema_root_node, module_name) do

    if not supported_schema_version?(schema_root_node) do
      exit(:bad_version)
    end

    {:ok, schema_id} = parse_schema_id(schema_root_node)
    title = Map.get(schema_root_node, "title", "")
    description = Map.get(schema_root_node, "description")

    handle_conflict = fn (key, value1, value2) ->
      Logger.error "Collision in type dict, found two values, " <>
        " '#{inspect value1}' and '#{inspect value2}' for key '#{key}'"
      exit(:invalid)
    end

    definitions = parse_definitions(schema_root_node, schema_id)
    root = parse_root_object(schema_root_node, schema_id, title)

    types =
      %{}
      |> Map.merge(definitions, handle_conflict)
      |> Map.merge(root, handle_conflict)

    %{to_string(schema_id) =>
      SchemaDefinition.new(schema_id, title, module_name, description, types)}
  end

  @spec parse_schema_id(any) :: {:ok, URI.t} | {:error, String.t}
  defp parse_schema_id(%{"id" => schema_id}) when is_binary(schema_id) do
    {:ok, URI.parse(schema_id)}
  end
  defp parse_schema_id(_) do
    {:error, "JSON schema has no 'id' property"}
  end

  @spec parse_definitions(map, URI.t) :: Types.typeDictionary
  defp parse_definitions(schema_root_node, schema_id) do
    if Predicates.definitions?(schema_root_node) do
      schema_root_node
      |> DefinitionsParser.parse(schema_id, nil, ["#"], "")
    else
      %{}
    end
  end

  @spec parse_root_object(map, URI.t, String.t) :: Types.typeDictionary
  defp parse_root_object(schema_root_node, schema_id, _title) do

    type_path = TypePath.from_string("#")
    name = "#"

    cond do
      Predicates.ref_type?(schema_root_node) ->
        schema_root_node
        |> TypeReferenceParser.parse(schema_id, schema_id, type_path, name)

      Predicates.object_type?(schema_root_node) ->
        schema_root_node
        |> parse_type(schema_id, [], name)

      Predicates.tuple_type?(schema_root_node) ->
        schema_root_node
        |> parse_type(schema_id, [], name)

      Predicates.array_type?(schema_root_node) ->
        schema_root_node
        |> parse_type(schema_id, [], name)

      true ->
        Logger.debug "Found no valid root object"
        %{}
    end
  end

  @spec parse_type(map, URI.t, TypePath.t, String.t) :: Types.typeDictionary
  def parse_type(schema_node, parent_id, path, name) do
    Logger.debug "Parsing type with name: #{name}, " <>
      "path: #{path}, and value: #{inspect schema_node}"

    node_parser = determine_node_parser(schema_node)
    Logger.debug "node_parser: #{inspect node_parser}"

    if node_parser != nil do

      id = determine_id(schema_node, parent_id)
      parent_id = determine_parent_id(id, parent_id)
      type_path = TypePath.add_child(path, name)
      node_parser.(schema_node, parent_id, id, type_path, name)

    else
      Logger.error "Could not determine parser for node: #{inspect schema_node}"
    end
  end

  @spec determine_id(map, URI.t) :: (URI.t | nil)
  defp determine_id(schema_node, parent_id) do
    id = schema_node["id"]

    if id != nil do
      id_uri = URI.parse(id)

      if id_uri.scheme == "urn" do
        id_uri
      else
        URI.merge(parent_id, id_uri)
      end

    else
      nil
    end
  end

  @spec determine_parent_id(URI.t | nil, URI.t) :: URI.t
  defp determine_parent_id(id, parent_id) do
    if id != nil && id.scheme != "urn" do
      id
    else
      parent_id
    end
  end

  @spec determine_node_parser(map) :: (nodeParser | nil)
  defp determine_node_parser(schema_node) do

    predicate_node_type_pairs = [
      {&Predicates.ref_type?/1, &TypeReferenceParser.parse/5},
      {&Predicates.enum_type?/1, &EnumParser.parse/5},
      {&Predicates.union_type?/1, &UnionParser.parse/5},
      {&Predicates.all_of_type?/1, &AllOfParser.parse/5},
      {&Predicates.any_of_type?/1, &AnyOfParser.parse/5},
      {&Predicates.one_of_type?/1, &OneOfParser.parse/5},
      {&Predicates.object_type?/1, &ObjectParser.parse/5},
      {&Predicates.array_type?/1, &ArrayParser.parse/5},
      {&Predicates.tuple_type?/1, &TupleParser.parse/5},
      {&Predicates.primitive_type?/1, &PrimitiveParser.parse/5},
      {&Predicates.definitions?/1, &DefinitionsParser.parse/5}
    ]

    predicate_node_type_pairs
    |> Enum.find({nil, nil}, fn {pred?, _node_parser} ->
      pred?.(schema_node)
    end)
    |> elem(1)
  end

  @spec supported_schema_version?(map) :: boolean
  defp supported_schema_version?(schema_root_node) do
    if Map.has_key?(schema_root_node, "$schema") do
      schema_identifier =
        schema_root_node
        |> Map.get("$schema")
        |> URI.parse

      (to_string schema_identifier) in @supported_versions
    else
      false
    end
  end

end
